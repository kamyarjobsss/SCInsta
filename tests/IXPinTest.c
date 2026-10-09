#include <stdio.h>
#include <string.h>

#include "../src/Backend/IXPin.h"

static int g_failed = 0;

static void expect(int cond, const char *name) {
    if (cond) {
        printf("ok %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    g_failed++;
}

int main(void) {
    static const uint8_t want[] = {
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
    };
    uint8_t point[65];
    uint8_t out[128];
    size_t n = 0;
    memset(point, 0xab, sizeof point);
    point[0] = 0x04;
    expect(sizeof want == IX_SPKI_P256_HEADER_LEN, "header is 26 bytes");
    expect(memcmp(IX_SPKI_P256_HEADER, want, sizeof want) == 0, "header matches the P-256 prefix");
    expect(IXSPKIBuildP256(point, 64, out, sizeof out, &n) == 0, "64-byte point is rejected");
    expect(IXSPKIBuildP256(point, 66, out, sizeof out, &n) == 0, "66-byte point is rejected");
    expect(IXSPKIBuildP256(point, 65, out, 26, &n) == 0, "short buffer is rejected");
    expect(IXSPKIBuildP256(point, 65, out, sizeof out, &n) == 1, "65-byte point builds");
    expect(n == 91, "spki is header plus point");
    expect(memcmp(out, want, sizeof want) == 0, "built spki starts with the header");
    expect(memcmp(out + sizeof want, point, 65) == 0, "built spki ends with the point");
    expect(IXSPKIPinAccept("nF3bL0hBLUH34FBfD4UJOkq/nY/a/VoH7kaD8ILcIOA=",
                           "nF3bL0hBLUH34FBfD4UJOkq/nY/a/VoH7kaD8ILcIOA=",
                           "3f4MhSKZEyhk7q1+RHZ/w0q54d4miKD92xZzBkIlewE=") == 1, "pin a");
    expect(IXSPKIPinAccept("3f4MhSKZEyhk7q1+RHZ/w0q54d4miKD92xZzBkIlewE=",
                           "nF3bL0hBLUH34FBfD4UJOkq/nY/a/VoH7kaD8ILcIOA=",
                           "3f4MhSKZEyhk7q1+RHZ/w0q54d4miKD92xZzBkIlewE=") == 1, "pin b");
    expect(IXSPKIPinAccept("other", "nF3bL0hBLUH34FBfD4UJOkq/nY/a/VoH7kaD8ILcIOA=",
                           "3f4MhSKZEyhk7q1+RHZ/w0q54d4miKD92xZzBkIlewE=") == 0, "other pin");
    expect(IXSPKIPinAccept("", "nF3bL0hBLUH34FBfD4UJOkq/nY/a/VoH7kaD8ILcIOA=", NULL) == 0, "empty pin");
    expect(IXSPKIPinAccept(NULL, "nF3bL0hBLUH34FBfD4UJOkq/nY/a/VoH7kaD8ILcIOA=", NULL) == 0, "null pin");
    return g_failed ? 1 : 0;
}
