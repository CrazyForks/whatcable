// Dump every USB hub node (AppleUSB20Hub / AppleUSB30Hub) and per-downstream-port
// node (AppleUSB20HubPort / AppleUSB30HubPort) in full, together with their whole
// child subtrees. No field filtering: everything the kernel exposes is captured,
// documented or not, because a field that looks useless today can matter for a
// later WhatCable feature or a sibling app.
//
// Why this exists: when a dock or hub throws macOS's "USB Accessories Disabled -
// using too much power" alert, that is a DOWNSTREAM overcurrent, inside the dock,
// on the port an accessory is plugged into. WhatCable's only overcurrent signal
// today is the Mac's OWN port controller (AppleHPMInterface "Overcurrent Count"),
// a step removed from the dock's downstream ports. These hub-port nodes carry a
// per-port "port-statistics" dict with lifetime-cumulative counters, including
// kPortStatOverCurrentCount (downstream overcurrent trips), kPortStatConnectCount
// (per-port plug events), and enumeration/address-failure counts, plus per-port
// current budgets (kUSBWakePortCurrentLimit / kUSBSleepPortCurrentLimit) and the
// hub's total supply (kUSBHubPowerSupply). No probe had ever run
// IORegistryEntryCreateCFProperties on these nodes. The child recursion also
// captures the connected devices behind each port and their interfaces.
//
// Data captured: USB topology, power budgets, health counters, and device
// descriptor strings. Those descriptor strings can include the model / product
// name and serial of an attached accessory. Those are hardware identifiers of a
// peripheral, WhatCable's join keys, the same class of data probes 04 and 38
// already collect on purpose; they identify a device, not a person or their Mac.
// Nothing here reads anything identifying the person or the Mac itself.
//
// A short upward parent chain (class + name + locationID) records which
// hub/controller each root sits under, so an offline replay can tell a dock's
// downstream ports from the Mac's own internal wiring.
//
// Safety mirrors probe 04: a visited-set (dump each node once, break any cycle),
// a depth cap, and a byte budget kept under the collector's output cap so a large
// tree is captured as far as it fits rather than discarded wholesale.
//
// Plain unprivileged registry read: no entitlement, no exclusive-access conflict,
// no USB control transfer.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 40_hub_port_statistics 40_hub_port_statistics.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>

static const long long kByteBudget = 3LL * 1024 * 1024;
// Registry-node recursion cap (runaway backstop; real subtrees are ~10 deep).
static const int kMaxDepth = 48;
// CF property-value recursion cap (nested dicts/arrays within one node). Real
// IOKit property graphs are a few levels deep; this only guards a pathologically
// deep or cyclic container from exhausting the stack before the budget stops it.
static const int kMaxValueDepth = 100;

// Upper bound on how many entries of one property dictionary we will buffer.
// Far above anything real (a busy node publishes tens), low enough that the
// allocation cannot get out of hand on a machine we do not control.
static const size_t kMaxDictEntries = 20000;

static long long g_bytes = 0;
static int g_truncatedNoted = 0;
// Visited-set, sized far above real use (a live multi-hub dock touches a few
// hundred nodes). If it ever saturates, dedup stops but the byte budget still
// hard-caps total output, so it degrades safely.
#define kSeenCap 65536u   /* power of two, for the mask below */
static uint64_t g_seen[kSeenCap];
static size_t g_seenCount = 0;

// printf wrapper that accumulates emitted bytes AND enforces the budget: once the
// budget is reached it emits nothing further, bounding total output to the budget
// plus at most one value's overshoot. overBudget() below prints the one-time
// marker and lets callers break their loops early.
static int emitf(const char *fmt, ...) {
    if (g_bytes >= kByteBudget) return 0;
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    if (n > 0) g_bytes += n;
    return n;
}

static int overBudget(void) {
    if (g_bytes < kByteBudget) return 0;
    if (!g_truncatedNoted) {
        g_truncatedNoted = 1;
        printf("\n[output budget reached: remaining nodes omitted to stay under the collector cap]\n");
    }
    return 1;
}

static int alreadySeen(io_service_t service) {
    uint64_t id = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &id) != KERN_SUCCESS) return 0;
    /* 0 marks an empty slot, so an id of 0 is simply never deduped. */
    if (id == 0) return 0;
    /* Open addressing with linear probing. The previous linear scan was O(n)
       per node, so a wide registry cost O(n^2) comparisons and could burn the
       runner's watchdog on a contributor's machine before the byte budget ever
       came into play. */
    const size_t mask = kSeenCap - 1u;
    /* Golden-ratio (Fibonacci) multiplicative hash, taking the TOP bits.
       Registry entry IDs are near-sequential, and the previous version
       multiplied by the FNV prime and took bits [17,33). That prime is
       2^40 + 435, so its 2^40 component never reaches that window and the
       result stayed near-linear in the low bits: 10,000 sequential ids
       landed in 34 buckets, and linear probing turned that single cluster
       back into the O(n^2) behaviour this set exists to avoid. Taking the
       top bits of the golden-ratio product spreads them properly (the same
       10,000 ids land in 10,000 buckets). */
    size_t h = (size_t)((id * 0x9E3779B97F4A7C15ULL) >> 48) & mask;
    for (size_t i = 0; i < kSeenCap; i++) {
        size_t slot = (h + i) & mask;
        if (g_seen[slot] == id) return 1;
        if (g_seen[slot] == 0) {
            /* Keep one slot free so the probe above always terminates. */
            if (g_seenCount < kSeenCap - 1u) {
                g_seen[slot] = id;
                g_seenCount++;
            }
            return 0;
        }
    }
    /* Saturated: stop deduping. The byte budget still bounds total output. */
    return 0;
}

static void dumpValue(CFTypeRef value, int indent, int vdepth);

static void dumpDict(CFDictionaryRef dict, int indent, int vdepth) {
    if (vdepth > kMaxValueDepth) { emitf("<max value depth>\n"); return; }
    CFIndex count = CFDictionaryGetCount(dict);
    if (count <= 0) return;
    /* A third-party driver can publish an enormous property dictionary. Cap the
       entry count before allocating: the two arrays below are 16 bytes per entry,
       so an unbounded count could demand hundreds of megabytes on someone else's
       machine even though the OUTPUT is capped. The check also rules out the
       size_t multiply overflowing. */
    if ((size_t)count > kMaxDictEntries) {
        emitf("<dictionary too large: %ld entries omitted>\n", (long)count);
        return;
    }
    const void **keys = malloc(sizeof(void*) * (size_t)count);
    const void **vals = malloc(sizeof(void*) * (size_t)count);
    if (!keys || !vals) { free(keys); free(vals); return; }
    CFDictionaryGetKeysAndValues(dict, keys, vals);

    for (CFIndex i = 0; i < count; i++) {
        if (overBudget()) break;
        for (int j = 0; j < indent; j++) emitf("  ");
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            char buf[256];
            buf[0] = '\0';
            if (CFStringGetCString(keys[i], buf, sizeof(buf), kCFStringEncodingUTF8)) {
                emitf("\"%s\": ", buf);
            } else {
                emitf("<unconvertible-key>: ");
            }
        } else {
            emitf("<key>: ");
        }
        dumpValue(vals[i], indent + 1, vdepth + 1);
    }
    free(keys);
    free(vals);
}

static void dumpValue(CFTypeRef value, int indent, int vdepth) {
    if (overBudget()) {
        /* The key label for this value has already been written, so returning
           silently would leave a dangling `"key": ` with no value and no
           newline. Terminate the line. Not routed through emitf for the same
           reason the budget marker is not: it must appear at the budget. Its
           enclosing loop breaks on the next iteration, so this fires at most
           once per open container. */
        printf("<truncated>\n");
        return;
    }
    if (vdepth > kMaxValueDepth) { emitf("<max value depth>\n"); return; }
    if (!value) { emitf("null\n"); return; }
    CFTypeID tid = CFGetTypeID(value);

    if (tid == CFStringGetTypeID()) {
        char buf[2048];
        buf[0] = '\0';
        if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            emitf("\"%s\"\n", buf);
        } else {
            emitf("<unconvertible string>\n");
        }
    } else if (tid == CFNumberGetTypeID()) {
        long long n = 0;
        if (CFNumberGetValue(value, kCFNumberLongLongType, &n)) {
            emitf("%lld (0x%llx)\n", n, n);
        } else {
            /* Out of range or otherwise not convertible: n would be
               indeterminate, so never print it. */
            emitf("<unconvertible number>\n");
        }
    } else if (tid == CFBooleanGetTypeID()) {
        emitf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *b = CFDataGetBytePtr(value);
        emitf("<data %ld>: ", len);
        for (CFIndex i = 0; i < len; i++) {
            if (overBudget()) break;
            emitf("%02x", b[i]);
            if (i < len - 1 && (i + 1) % 4 == 0) emitf(" ");
        }
        emitf("\n");
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        emitf("[\n");
        for (CFIndex i = 0; i < count; i++) {
            if (overBudget()) break;
            for (int j = 0; j < indent; j++) emitf("  ");
            emitf("[%ld] ", i);
            dumpValue(CFArrayGetValueAtIndex(value, i), indent + 1, vdepth + 1);
        }
        for (int j = 0; j < indent - 1; j++) emitf("  ");
        emitf("]\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        emitf("{\n");
        dumpDict(value, indent, vdepth + 1);
        for (int j = 0; j < indent - 1; j++) emitf("  ");
        emitf("}\n");
    } else {
        emitf("<type-%lu>\n", tid);
    }
}

// The upward join context for a root: which hub/controller it sits under. Kept
// light (class + name + locationID); those ancestors are captured in full when
// they are matched as their own roots (here or in probe 04).
static void dumpParents(io_service_t service) {
    if (overBudget()) return;
    emitf("  Parent chain (service plane):\n");
    io_service_t current = service;
    IOObjectRetain(current);
    for (int hop = 0; hop < 8; hop++) {
        io_service_t parent = 0;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) {
            IOObjectRelease(current);
            current = 0;
            break;
        }
        IOObjectRelease(current);
        current = parent;

        io_name_t cls = {0}, nm = {0};
        IOObjectGetClass(current, cls);
        IORegistryEntryGetName(current, nm);

        CFTypeRef locRef = IORegistryEntryCreateCFProperty(current, CFSTR("locationID"), kCFAllocatorDefault, 0);
        long long loc = -1;
        if (locRef && CFGetTypeID(locRef) == CFNumberGetTypeID())
            CFNumberGetValue(locRef, kCFNumberLongLongType, &loc);
        if (locRef) CFRelease(locRef);

        emitf("    [%d] class=%s name=%s", hop, cls, nm);
        if (loc >= 0) emitf(" locationID=0x%llx", (unsigned long long)loc);
        emitf("\n");
    }
    if (current) IOObjectRelease(current);
}

// Dump one node (class, name, all properties) then recurse into every child.
//
// `forceOwnProperties` makes this node dump its own properties even if it was
// already reached under some other root. Every explicitly matched root passes 1.
// Without it, a hub or port reached first as another root's descendant had its
// own section reduced to a bare "[already dumped]" line carrying no per-port
// statistics at all, which is the entire point of this probe.
static void dumpNode(io_service_t service, int depth, int forceOwnProperties) {
    if (depth > kMaxDepth) return;
    if (overBudget()) {
        /* A root whose section header was the write that crossed the budget
           would otherwise leave a header with nothing beneath it, which reads
           like a device with no properties rather than a truncated dump. Say
           so explicitly. Raw printf for the same reason as the budget marker,
           and bounded because only matched roots pass forceOwnProperties. */
        if (forceOwnProperties) printf("[properties omitted: output budget reached]\n");
        return;
    }

    io_name_t name = {0}, cls = {0};
    IORegistryEntryGetName(service, name);
    IOObjectGetClass(service, cls);

    if (alreadySeen(service) && !forceOwnProperties) {
        for (int j = 0; j < depth; j++) emitf("  ");
        emitf("- %s (name: %s) [already dumped, see above]\n", cls, name);
        return;
    }

    for (int j = 0; j < depth; j++) emitf("  ");
    emitf("- %s (name: %s) [depth %d]\n", cls, name, depth);

    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        dumpDict(props, depth + 1, 0);
        CFRelease(props);
    }

    io_iterator_t children;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(children))) {
            // Stop walking, not just writing: see the note in probe 04.
            if (overBudget()) { IOObjectRelease(child); break; }
            dumpNode(child, depth + 1, 0);
            IOObjectRelease(child);
        }
        IOObjectRelease(children);
    }
}

static void dumpAllMatchingServices(const char *className) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching(className),
        &iter
    );
    if (kr != KERN_SUCCESS) {
        emitf("\n(no match / error for class %s)\n", className);
        return;
    }

    io_service_t service;
    int idx = 0;
    while ((service = IOIteratorNext(iter))) {
        if (overBudget()) { IOObjectRelease(service); break; }
        io_name_t name = {0}, cls = {0};
        IORegistryEntryGetName(service, name);
        IOObjectGetClass(service, cls);

        emitf("\n========================================\n");
        emitf("%s[%d] (name: %s, class: %s)\n", className, idx++, name, cls);
        emitf("========================================\n");

        dumpParents(service);
        dumpNode(service, 0, 1);
        IOObjectRelease(service);
    }
    if (idx == 0) emitf("\n(class %s matched but zero instances)\n", className);
    IOObjectRelease(iter);
}

int main(void) {
    emitf("=== USB hub per-downstream-port statistics (full subtree) ===\n");
    emitf("AppleUSB2x/3xHub + AppleUSB2x/3xHubPort roots, each with its parent\n");
    emitf("chain and full child subtree. Empty when no hub or dock is attached.\n");

    const char *classes[] = {
        "AppleUSB20HubPort",
        "AppleUSB30HubPort",
        "AppleUSB20Hub",
        "AppleUSB30Hub",
        NULL
    };
    for (int i = 0; classes[i]; i++) {
        if (overBudget()) break;
        emitf("\n\n################ %s ################\n", classes[i]);
        dumpAllMatchingServices(classes[i]);
    }
    return 0;
}
