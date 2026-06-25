// Capture the IOUSB device tree with the ancestor walk WhatCable's classifier
// actually consumes, so the "which device shows, and where" logic can be
// replayed offline against real machines.
//
// Why this exists: WhatCable decides where each USB device appears (under a
// physical port, behind a Thunderbolt dock, or on a desktop front panel) in
// USBWatcher.controllerInfo, which walks UP the IOService plane from each
// IOUSBHostDevice to its host controller, reading the class name, USBPortType,
// and UsbIOPort of every ancestor along the way. The existing probes dump
// device properties flat and throw that ancestor chain away, so the
// classification can never be tested against real hardware. This probe records,
// for every connected USB device, the exact ancestor walk the classifier reads:
//
//     device -> hub(s) -> ... -> host controller (AppleT*USBXHCI / AppleUSBXHCITR
//                                / dock XHCI)
//
// With this, an offline replay can reconstruct reachedNativeController,
// tunnelled, portName, and hubPortType and run the real classifier, plus rebuild
// the device tree from the locationIDs. Property keys mirror USBWatcher exactly
// (idVendor, idProduct, locationID, Device Speed, bDeviceClass, USB Product /
// Vendor Name; UsbIOPort and USBPortType on ancestors).
//
// No personal data: USB serial numbers are deliberately NOT captured.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 38_usb_device_tree 38_usb_device_tree.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

// Read a CFNumber property as long long. Returns sentinel if absent.
static long long readNumber(io_service_t s, CFStringRef key, long long sentinel) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    long long out = sentinel;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberLongLongType, &out);
    }
    if (v) CFRelease(v);
    return out;
}

// Copy a CFString property into buf. Returns 1 on success, 0 if absent.
static int readString(io_service_t s, CFStringRef key, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
    }
    if (v) CFRelease(v);
    return ok;
}

// Read UsbIOPort, which macOS stores as either a CFString or UTF-8 CFData
// (the path tail "Port-USB-C@N" is what matters). Returns 1 if present.
static int readUsbIOPort(io_service_t s, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFSTR("UsbIOPort"), kCFAllocatorDefault, 0);
    int ok = 0;
    if (v) {
        CFTypeID t = CFGetTypeID(v);
        if (t == CFStringGetTypeID()) {
            ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
        } else if (t == CFDataGetTypeID()) {
            CFIndex len = CFDataGetLength(v);
            if (len > 0) {
                if ((size_t)len >= n) len = n - 1;
                memcpy(buf, CFDataGetBytePtr(v), len);
                buf[len] = '\0';
                ok = 1;
            }
        }
        CFRelease(v);
    }
    return ok;
}

// Print the ancestor walk for one device: every IOService-plane parent up to
// the host controller, capturing the fields the classifier reads. Bounded at 20
// hops to match USBWatcher.controllerInfo and guard against a cyclic registry.
static void dumpAncestors(io_service_t device) {
    printf("  Ancestors (device -> controller):\n");
    io_service_t current = device;
    IOObjectRetain(current);
    for (int hop = 0; hop < 20; hop++) {
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

        long long loc = readNumber(current, CFSTR("locationID"), -1);
        long long portType = readNumber(current, CFSTR("USBPortType"), -1);
        // 512 so a deep nested-hub UsbIOPort path is never truncated: the
        // classifier reads the "Port-*" tail, which a short buffer could drop.
        char ioPort[512];
        int hasPort = readUsbIOPort(current, ioPort, sizeof(ioPort));

        printf("    [%d] class=%s", hop, cls);
        if (loc >= 0) printf(" locationID=0x%llx", (unsigned long long)loc);
        if (portType >= 0) printf(" USBPortType=%lld", portType);
        if (hasPort && ioPort[0]) printf(" UsbIOPort=%s", ioPort);
        printf("\n");

        // Stop at the host controller, mirroring USBWatcher.controllerInfo /
        // isThunderboltDockController EXACTLY so an offline replay reaches the
        // same node production does:
        //   tunnel = AppleUSBXHCITR prefix
        //   native = AppleT* prefix AND ends with "USBXHCI" (so the M5 Pro/Max
        //            AppleT6050USBXHCIAUSS, which does NOT end in USBXHCI, is not
        //            treated as native, exactly as production)
        //   dock   = contains "USBXHCI" and is none of AppleT* / AppleUSBXHCITR /
        //            AppleIntel*
        const char *c = cls;
        size_t clen = strlen(c);
        int hasXHCI = strstr(c, "USBXHCI") != NULL;
        int endsXHCI = clen >= 7 && strcmp(c + clen - 7, "USBXHCI") == 0;
        int isTunnel = strncmp(c, "AppleUSBXHCITR", 14) == 0;
        int isNative = strncmp(c, "AppleT", 6) == 0 && endsXHCI;
        int isDock = hasXHCI
            && strncmp(c, "AppleT", 6) != 0
            && strncmp(c, "AppleUSBXHCITR", 14) != 0
            && strncmp(c, "AppleIntel", 10) != 0;
        if (isTunnel || isNative || isDock) {
            printf("    (reached host controller: %s)\n", cls);
            IOObjectRelease(current);
            current = 0;
            break;
        }
    }
    if (current) IOObjectRelease(current);
}

int main(void) {
    printf("=== USB device tree (per-device ancestor walk for classification replay) ===\n");
    printf("Mirrors USBWatcher.controllerInfo: each device, then its IOService-plane\n");
    printf("ancestors up to the host controller, with class / USBPortType / UsbIOPort.\n\n");

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOUSBHostDevice"), &iter) != KERN_SUCCESS) {
        printf("(IOUSBHostDevice match failed)\n");
        return 0;
    }

    io_service_t s;
    int n = 0;
    while ((s = IOIteratorNext(iter))) {
        char product[256], vendor[256];
        if (!readString(s, CFSTR("USB Product Name"), product, sizeof(product)) || !product[0]) {
            io_name_t nm = {0};
            IORegistryEntryGetName(s, nm);
            snprintf(product, sizeof(product), "%s", nm);
        }
        if (!readString(s, CFSTR("USB Vendor Name"), vendor, sizeof(vendor))) vendor[0] = '\0';

        long long loc   = readNumber(s, CFSTR("locationID"), -1);
        long long vid   = readNumber(s, CFSTR("idVendor"), -1);
        long long pid   = readNumber(s, CFSTR("idProduct"), -1);
        long long speed = readNumber(s, CFSTR("Device Speed"), -1);
        long long klass = readNumber(s, CFSTR("bDeviceClass"), -1);

        printf("--- Device[%d] ---\n", n);
        printf("  USB Product Name = \"%s\"\n", product);
        printf("  USB Vendor Name = \"%s\"\n", vendor);
        printf("  locationID = 0x%llx\n", (unsigned long long)(loc < 0 ? 0 : loc));
        printf("  idVendor = 0x%llx\n", (unsigned long long)(vid < 0 ? 0 : vid));
        printf("  idProduct = 0x%llx\n", (unsigned long long)(pid < 0 ? 0 : pid));
        printf("  Device Speed = %lld\n", speed);
        printf("  bDeviceClass = %lld\n", klass);
        dumpAncestors(s);
        printf("\n");

        n++;
        IOObjectRelease(s);
    }
    if (n == 0) printf("(no USB devices connected)\n");
    IOObjectRelease(iter);
    return 0;
}
