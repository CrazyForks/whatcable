/*
 * 29_usb4_router_interfaces.c - Probe USB4 router and hub services.
 * USB4 hubs/docks expose standard USB descriptors. Try to find and read
 * them, including device/config/BOS descriptors via IOUSBHostInterface.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 29_usb4_router_interfaces 29_usb4_router_interfaces.c
 */

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach.h>

static void printCFType(CFTypeRef value, int indent) {
    char pad[64] = {0};
    for (int i = 0; i < indent && i < 60; i++) pad[i] = ' ';

    if (!value) { printf("%s(null)\n", pad); return; }

    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512];
        CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8);
        printf("%s\"%s\"\n", pad, buf);
    } else if (tid == CFNumberGetTypeID()) {
        long long num = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%s%lld (0x%llx)\n", pad, num, num);
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        printf("%sData[%ld]: ", pad, (long)len);
        for (CFIndex i = 0; i < len && i < 64; i++)
            printf("%02x ", bytes[i]);
        if (len > 64) printf("...");
        printf("\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        CFIndex n = CFDictionaryGetCount(value);
        const void **keys = malloc(n * sizeof(void*));
        const void **vals = malloc(n * sizeof(void*));
        CFDictionaryGetKeysAndValues(value, keys, vals);
        for (CFIndex i = 0; i < n; i++) {
            char kbuf[256];
            CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8);
            printf("%s  %s = ", pad, kbuf);
            printCFType(vals[i], indent + 4);
        }
        free(keys); free(vals);
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        for (CFIndex i = 0; i < count; i++) {
            printf("%s  [%ld] ", pad, (long)i);
            printCFType(CFArrayGetValueAtIndex(value, i), indent + 4);
        }
    } else {
        printf("%s<type %lu>\n", pad, (unsigned long)tid);
    }
}

static void dumpService(io_service_t service, const char *label) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props,
        kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) return;

    printf("\n--- %s ---\n", label);

    CFIndex n = CFDictionaryGetCount(props);
    const void **keys = malloc(n * sizeof(void*));
    const void **vals = malloc(n * sizeof(void*));
    CFDictionaryGetKeysAndValues(props, keys, vals);
    for (CFIndex i = 0; i < n; i++) {
        char kbuf[256];
        CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8);
        printf("  %s = ", kbuf);
        printCFType(vals[i], 4);
    }
    free(keys); free(vals);
    CFRelease(props);

    // Try opening user client
    io_connect_t conn;
    kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    if (kr == KERN_SUCCESS) {
        printf("  ** User client OPEN (type=0) **\n");
        IOServiceClose(conn);
    }
}

// For an IOThunderboltSwitch, emit its own registry entry ID and its parent
// switch's registry entry ID. The parent linkage lives in the IOService-plane
// nesting (a downstream switch sits below its parent), which the flat property
// dump above loses, so the topology tree cannot be rebuilt offline without it.
// Mirrors IOThunderboltSwitchWatcher.parentSwitchEntryID: walk up, match the
// first ancestor whose class is IOThunderboltSwitch* or IOIOThunderboltSwitch*
// (both naming families across Mac generations), take its registry entry ID.
static void dumpSwitchParentage(io_service_t svc) {
    uint64_t entryID = 0;
    IORegistryEntryGetRegistryEntryID(svc, &entryID);
    printf("  RegistryEntryID = %llu (0x%llx)\n",
           (unsigned long long)entryID, (unsigned long long)entryID);

    uint64_t parentEntryID = 0;
    io_service_t current = svc;
    IOObjectRetain(current);
    for (int hop = 0; hop < 32; hop++) {
        io_service_t parent = 0;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) {
            IOObjectRelease(current);
            current = 0;
            break;
        }
        IOObjectRelease(current);
        current = parent;
        io_name_t cls = {0};
        IOObjectGetClass(current, cls);
        if (strncmp(cls, "IOIOThunderboltSwitch", 21) == 0 ||
            strncmp(cls, "IOThunderboltSwitch", 19) == 0) {
            IORegistryEntryGetRegistryEntryID(current, &parentEntryID);
            IOObjectRelease(current);
            current = 0;
            break;
        }
    }
    if (current) IOObjectRelease(current);
    printf("  ParentSwitchEntryID = %llu (0x%llx)\n",
           (unsigned long long)parentEntryID, (unsigned long long)parentEntryID);
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    io_iterator_t iter;
    kern_return_t kr;
    io_service_t svc;

    // USB4 / Thunderbolt router classes
    const char *classes[] = {
        "IOThunderboltUSB4Router",
        "IOThunderboltUSB4HostRouter",
        "IOThunderboltUSB4DeviceRouter",
        "AppleUSB4Hub",
        "AppleUSB40HostPort",
        "AppleUSB40DevicePort",
        "IOThunderboltNHI",
        "IOUSBHostInterface",
        "IOThunderboltPort",
        "IOThunderboltSwitch",
        "IOIOThunderboltSwitch",
        "IOThunderboltConnection",
        NULL
    };

    for (int c = 0; classes[c]; c++) {
        printf("=== %s ===\n", classes[c]);
        kr = IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(classes[c]), &iter);
        if (kr != KERN_SUCCESS) {
            printf("  (not found)\n\n");
            continue;
        }

        int count = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            io_name_t name;
            IORegistryEntryGetName(svc, name);
            char label[256];
            snprintf(label, sizeof(label), "%s[%d] \"%s\"", classes[c], count, name);
            dumpService(svc, label);
            // For switches (both the IOThunderboltSwitch* and older
            // IOIOThunderboltSwitch* naming families), also record the parent
            // linkage (entry IDs) the flat property dump drops, so the topology
            // tree can be rebuilt offline.
            if (strcmp(classes[c], "IOThunderboltSwitch") == 0 ||
                strcmp(classes[c], "IOIOThunderboltSwitch") == 0) {
                dumpSwitchParentage(svc);
            }
            IOObjectRelease(svc);
            count++;
            if (count > 5 && strcmp(classes[c], "IOUSBHostInterface") == 0) {
                printf("  ... (truncating, %d+ interfaces)\n", count);
                break;
            }
        }
        IOObjectRelease(iter);
        if (count == 0) printf("  (no instances)\n");
        printf("\n");
    }

    return 0;
}
