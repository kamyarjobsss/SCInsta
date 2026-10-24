#ifndef IX_PIN_H
#define IX_PIN_H

#include <stddef.h>
#include <stdint.h>

/* ASN.1 SubjectPublicKeyInfo prefix for an EC P-256 key.
   SecKeyCopyExternalRepresentation returns the raw 65-byte point.
   SHA-256 is over this prefix followed by that point. */
#define IX_SPKI_P256_HEADER_LEN 26
#define IX_SPKI_P256_POINT_LEN 65

extern const uint8_t IX_SPKI_P256_HEADER[IX_SPKI_P256_HEADER_LEN];

/* Writes header || point. Returns 0 when the point is not 65 bytes
   or the output buffer is too small. */
int IXSPKIBuildP256(const uint8_t *point, size_t point_len, uint8_t *out, size_t out_cap, size_t *out_len);

/* 1 when `computed` equals either pin. Empty and null never match. */
int IXSPKIPinAccept(const char *computed, const char *pin_a, const char *pin_b);

#endif
