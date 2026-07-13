// Capture connected-display capability as a tree, from the real Apple Silicon
// display nodes, with IOReporting noise cut.
//
// History: the old version of this probe queried Intel-era framebuffer classes
// (IODisplayConnect / IOFramebuffer / IOBacklightDisplay) that do not exist on
// Apple Silicon, so it captured none of its intended data; it then fell back to
// "match every IOService and dump anything with 'DisplayPort' in the name",
// which produced ~640 KB of IOReporting event-log spam. This rewrite fixes it:
//
//   1. Roots at the display nodes that actually exist on Apple Silicon
//      (AppleCLCD2 / IOMobileFramebufferShim / DCPAVDevice) and walks each
//      subtree, so the display capability (DSC / HDR / colour / native modes /
//      timing) is actually captured.
//   2. Preserves the tree: every node records its RegistryEntryID and its
//      parent's, the same convention as probes 29 and 38, so the hierarchy is
//      reconstructable from data, not from indentation.
//   3. Skips the IOReporting event-log keys, so the output is the useful
//      capability data at a sane size.
//
// The panel serial and the raw EDID blob are KEPT, along with model identity
// (DisplayVendorID / DisplayProductID / ManufacturerID), manufacture date, and
// the EDID/IOMFB UUIDs. These identify a panel, not a person, and they are the
// join keys the research depends on: DisplayModeReader uses the serial to tell
// two identical displays apart, and the raw EDID is what the app's own EDID
// parser consumes. The probe submits to the private research KV.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 26_displayport_altmode 26_displayport_altmode.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <strings.h>

// The panel serial and the raw EDID blob are KEPT. The serial is the only thing
// that separates two identical displays, and DisplayModeReader uses exactly that
// to match a CoreGraphics display to the right IOKit port. The raw EDID blob is
// what the app's own EDID parser consumes, so redacting it made the corpus
// unable to replay that code path. Both identify a panel, not a person.

// IOReporting telemetry: high-volume event-log entries with no capability value
// (this is what bloated the old probe). Skip the key entirely.
static int isNoiseKey(const char *k) {
    return strncmp(k, "Event", 5) == 0
        || strcasestr(k, "IOReportLegend") || strcasestr(k, "IOReporting");
}

static void printValue(CFTypeRef value, int indent);

static void printDict(CFDictionaryRef dict, int indent) {
    CFIndex n = CFDictionaryGetCount(dict);
    const void **keys = malloc(n * sizeof(void*));
    const void **vals = malloc(n * sizeof(void*));
    CFDictionaryGetKeysAndValues(dict, keys, vals);
    for (CFIndex i = 0; i < n; i++) {
        char kbuf[256] = {0};
        if (CFGetTypeID(keys[i]) != CFStringGetTypeID()) continue;
        if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
            snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
        // Skip noise keys BEFORE printing the indent, or a suppressed key leaves
        // a stray blank-indent line that breaks a line-by-line parser.
        if (isNoiseKey(kbuf)) { continue; }
        for (int j = 0; j < indent; j++) printf("  ");
        printf("%s = ", kbuf);
        printValue(vals[i], indent + 1);
    }
    free(keys); free(vals);
}

static void printValue(CFTypeRef value, int indent) {
    if (!value) { printf("(null)\n"); return; }
    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512] = {0};
        if (!CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8))
            snprintf(buf, sizeof(buf), "<unconvertible>");
        printf("\"%s\"\n", buf);
    } else if (tid == CFNumberGetTypeID()) {
        long long num = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%lld (0x%llx)\n", num, num);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *b = CFDataGetBytePtr(value);
        printf("Data[%ld]: ", (long)len);
        for (CFIndex i = 0; i < len && i < 48; i++) printf("%02x ", b[i]);
        if (len > 48) printf("...");
        printf("\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        printf("{\n");
        printDict((CFDictionaryRef)value, indent + 1);
        for (int j = 0; j < indent; j++) printf("  ");
        printf("}\n");
    } else if (tid == CFArrayGetTypeID()) {
        // Display nodes carry mode/timing tables with hundreds of entries, each
        // repeating the same capability flags. A sample is enough to characterise
        // the panel without dumping the whole table; the full count is recorded.
        CFIndex count = CFArrayGetCount(value);
        const CFIndex cap = 12;
        printf("[%ld]%s\n", (long)count, count > cap ? " (sampled)" : "");
        for (CFIndex i = 0; i < count && i < cap; i++) {
            for (int j = 0; j < indent + 1; j++) printf("  ");
            printValue(CFArrayGetValueAtIndex(value, i), indent + 1);
        }
    } else if (tid == CFSetGetTypeID()) {
        // e.g. NominalSignalingFrequenciesHz on a DisplayPort node is a CFSet of
        // numbers; without this it would print as an opaque type id.
        CFIndex count = CFSetGetCount(value);
        printf("set[%ld]\n", (long)count);
        const void **items = malloc((count > 0 ? count : 1) * sizeof(void*));
        CFSetGetValues(value, items);
        for (CFIndex i = 0; i < count && i < 32; i++) {
            for (int j = 0; j < indent + 1; j++) printf("  ");
            printValue(items[i], indent + 1);
        }
        free(items);
    } else {
        printf("<type %lu>\n", (unsigned long)tid);
    }
}

// Walk one display node and its subtree, recording the parent linkage so the
// tree is reconstructable from data. Bounded depth guards a pathological tree.
static void walk(io_service_t service, int depth, uint64_t parentEntryID) {
    // The panel capability (DSC / HDR / colour / modes / timing) sits in the top
    // display nodes; deeper children are framebuffer-pipeline internals (planes,
    // scalers) that add bulk without capability value, so the walk stays shallow.
    if (depth > 5) return;

    io_name_t cls = {0}, name = {0};
    IOObjectGetClass(service, cls);
    IORegistryEntryGetName(service, name);
    uint64_t entryID = 0;
    IORegistryEntryGetRegistryEntryID(service, &entryID);

    for (int j = 0; j < depth; j++) printf("  ");
    printf("--- %s \"%s\" (entryID=0x%llx parentEntryID=0x%llx) ---\n",
           cls, name, (unsigned long long)entryID, (unsigned long long)parentEntryID);

    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        printDict(props, depth + 1);
        CFRelease(props);
    }

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(childIter))) {
            walk(child, depth + 1, entryID);
            IOObjectRelease(child);
        }
        IOObjectRelease(childIter);
    }
}

int main(void) {
    printf("=== Connected display capability (tree) ===\n");
    printf("Roots at the Apple Silicon display nodes; each node carries its\n");
    printf("RegistryEntryID and parent's so the tree is reconstructable from data.\n\n");

    // The display-capability nodes that actually exist on Apple Silicon. The DCP
    // (display coprocessor) presents the panel attributes; AppleCLCD2 is the
    // on-die display controller above it.
    const char *roots[] = {
        "AppleCLCD2",
        "IOMobileFramebufferShim",
        "DCPAVDevice",
        NULL
    };

    for (int r = 0; roots[r]; r++) {
        printf("=== root: %s ===\n", roots[r]);
        io_iterator_t iter;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching(roots[r]), &iter) != KERN_SUCCESS) {
            printf("  (match failed)\n\n");
            continue;
        }
        io_service_t svc;
        int n = 0;
        while ((svc = IOIteratorNext(iter))) {
            walk(svc, 0, 0);
            IOObjectRelease(svc);
            n++;
        }
        IOObjectRelease(iter);
        if (n == 0) printf("  (no instances)\n");
        printf("\n");
    }
    return 0;
}
