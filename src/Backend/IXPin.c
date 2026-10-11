#include "IXPin.h"

#include <string.h>

const uint8_t IX_SPKI_P256_HEADER[IX_SPKI_P256_HEADER_LEN] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
};

int IXSPKIBuildP256(const uint8_t *point, size_t point_len, uint8_t *out, size_t out_cap, size_t *out_len) {
    if (out_len) *out_len = 0;
    if (!point || point_len != IX_SPKI_P256_POINT_LEN || !out) return 0;
    if (out_cap < IX_SPKI_P256_HEADER_LEN + IX_SPKI_P256_POINT_LEN) return 0;
    memcpy(out, IX_SPKI_P256_HEADER, IX_SPKI_P256_HEADER_LEN);
    memcpy(out + IX_SPKI_P256_HEADER_LEN, point, IX_SPKI_P256_POINT_LEN);
    if (out_len) *out_len = IX_SPKI_P256_HEADER_LEN + IX_SPKI_P256_POINT_LEN;
    return 1;
}

int IXSPKIPinAccept(const char *computed, const char *pin_a, const char *pin_b) {
    if (!computed || !computed[0]) return 0;
    if (pin_a && pin_a[0] && strcmp(computed, pin_a) == 0) return 1;
    if (pin_b && pin_b[0] && strcmp(computed, pin_b) == 0) return 1;
    return 0;
}
