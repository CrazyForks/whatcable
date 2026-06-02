/*
 * 34_smc_power_keys.c - Dump every AppleSMC key with type, size, raw bytes and
 * a best-effort decoded value.
 *
 * Why: per-port USB-C power is only surfaced through AppleSmartBattery's
 * PowerOutDetails, which desktops (iMac, Mac mini, Studio, Mac Pro) do not have.
 * The System Management Controller is the other place a system-level or USB-rail
 * power/current/voltage reading could live, and we have never enumerated it.
 * This probe dumps the full key set so the power/current/voltage keys can be
 * mined afterwards (same dump-everything approach as the BOS and CIO probes).
 *
 * SMC is reached through IOKit (IOServiceOpen on AppleSMC), so no extra
 * framework is needed. Read-only: it only reads keys, never writes.
 *
 * To actually capture power flowing OUT of a port, run this on a desktop while a
 * USB-C port is charging a device (phone/iPad), not on an idle machine.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 34_smc_power_keys 34_smc_power_keys.c
 */

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// AppleSMC user-client call structure and selectors. This layout is the
// long-standing public ABI used by smcFanControl, libsmc and powermetrics.
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;

typedef struct {
    UInt32      key;
    SMCVers     vers;
    SMCPLimit   pLimit;
    SMCKeyInfo  keyInfo;
    char        result;
    char        status;
    char        data8;
    UInt32      data32;
    char        bytes[32];
} SMCParam;

enum { kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };
#define KERNEL_INDEX_SMC 2

// Pack a 4-char key/type into its FourCC UInt32 (MSB first).
static UInt32 fourCC(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16)
         | ((UInt32)(unsigned char)s[2] << 8)  |  (UInt32)(unsigned char)s[3];
}

// Unpack a FourCC UInt32 into a printable 4-char string (+NUL). Non-printable
// bytes are shown as '.', so a numeric type code still produces readable output.
static void unFourCC(UInt32 v, char out[5]) {
    out[0] = (v >> 24) & 0xff; out[1] = (v >> 16) & 0xff;
    out[2] = (v >> 8) & 0xff;  out[3] = v & 0xff; out[4] = 0;
    for (int i = 0; i < 4; i++) if (out[i] < 32 || out[i] > 126) out[i] = '.';
}

static kern_return_t smcCall(io_connect_t conn, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &outSize);
}

// Read big-endian unsigned integer of `size` bytes (SMC returns MSB first).
static unsigned long long beUInt(const char *b, UInt32 size) {
    unsigned long long v = 0;
    for (UInt32 i = 0; i < size && i < 8; i++) v = (v << 8) | (unsigned char)b[i];
    return v;
}

// Best-effort decode of a value by its SMC type code. Always prints the raw hex
// bytes first so nothing is lost when a type is not recognised.
static void printValue(const char *type, const char *bytes, UInt32 size) {
    printf("raw=");
    for (UInt32 i = 0; i < size && i < 32; i++) printf("%02x", (unsigned char)bytes[i]);

    if (size == 0) { printf("  (empty)"); return; }

    unsigned long long u = beUInt(bytes, size);

    if (strncmp(type, "ui", 2) == 0) {
        printf("  = %llu", u);
    } else if (strncmp(type, "si", 2) == 0) {
        long long s = u;
        unsigned long long sign = 1ULL << (size * 8 - 1);
        if (size < 8 && (u & sign)) s = (long long)(u - (sign << 1)); // sign-extend
        printf("  = %lld", s);
    } else if (strncmp(type, "flt", 3) == 0 && size == 4) {
        float f; memcpy(&f, bytes, 4); // SMC float bytes are native order on this arch
        printf("  = %.4f", f);
    } else if ((type[0] == 's' || type[0] == 'f') && type[1] == 'p' && size == 2) {
        // Fixed point spIF / fpIF: I integer bits, F fraction bits (hex digits).
        int frac = (type[3] >= 'a') ? (type[3] - 'a' + 10) : (type[3] - '0');
        if (frac < 0 || frac > 15) frac = 0;
        double scale = (double)(1u << frac);
        if (type[0] == 's') {
            short raw = (short)u;
            printf("  = %.4f", raw / scale);
        } else {
            printf("  = %.4f", (unsigned short)u / scale);
        }
    }
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    io_service_t smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!smc) { printf("=== AppleSMC ===\n  (service not found)\n"); return 0; }

    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(smc, mach_task_self(), 0, &conn);
    IOObjectRelease(smc);
    if (kr != KERN_SUCCESS) {
        printf("=== AppleSMC ===\n  IOServiceOpen failed: 0x%x (need no entitlement for reads, but report it)\n", kr);
        return 0;
    }

    // #KEY returns the total number of keys as a ui32.
    SMCParam in = {0}, out = {0};
    in.key = fourCC("#KEY");
    in.data8 = kSMCGetKeyInfo;
    if (smcCall(conn, &in, &out) != KERN_SUCCESS) { printf("=== AppleSMC ===\n  #KEY info failed\n"); IOServiceClose(conn); return 0; }
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = fourCC("#KEY");
    in.keyInfo.dataSize = 4;
    in.data8 = kSMCReadKey;
    smcCall(conn, &in, &out);
    UInt32 total = (UInt32)beUInt(out.bytes, 4);

    printf("=== AppleSMC keys ===\n");
    printf("  Total keys: %u\n\n", total);
    printf("  KEY  type  size  value\n");

    for (UInt32 i = 0; i < total; i++) {
        // index -> key
        memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
        in.data8 = kSMCGetKeyFromIndex;
        in.data32 = i;
        if (smcCall(conn, &in, &out) != KERN_SUCCESS || out.key == 0) continue;
        UInt32 key = out.key;

        // key -> info (size + type)
        memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
        in.key = key;
        in.data8 = kSMCGetKeyInfo;
        if (smcCall(conn, &in, &out) != KERN_SUCCESS) continue;
        UInt32 size = out.keyInfo.dataSize;
        UInt32 typeCC = out.keyInfo.dataType;

        // key -> value
        memset(&out, 0, sizeof(out));
        memset(&in, 0, sizeof(in));
        in.key = key;
        in.keyInfo.dataSize = size;
        in.keyInfo.dataType = typeCC;
        in.data8 = kSMCReadKey;
        kern_return_t rk = smcCall(conn, &in, &out);

        char keyStr[5], typeStr[5];
        unFourCC(key, keyStr);
        unFourCC(typeCC, typeStr);
        printf("  %-4s %-4s %2u    ", keyStr, typeStr, size);
        if (rk == KERN_SUCCESS) {
            printValue(typeStr, out.bytes, size > 32 ? 32 : size);
        } else {
            printf("(read failed 0x%x)", rk);
        }
        printf("\n");
    }

    IOServiceClose(conn);
    return 0;
}
