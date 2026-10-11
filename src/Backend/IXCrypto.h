#ifndef IX_CRYPTO_H
#define IX_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// SHA-256. Returns 0.
int ix_sha256(const uint8_t *data, size_t len, uint8_t out[32]);

/// HKDF-SHA256 (RFC 5869). salt and info may be NULL when their length is 0.
int ix_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                   const uint8_t *salt, size_t salt_len,
                   const uint8_t *info, size_t info_len,
                   uint8_t *okm, size_t okm_len);

/// AES-256-GCM. combined is nonce(12) || ciphertext || tag(16). No AAD.
/// plain_len in is the capacity; out is the plaintext length. Returns 0 on success.
int ix_aes256_gcm_open(const uint8_t key[32], const uint8_t *combined, size_t combined_len,
                       uint8_t *plain, size_t *plain_len);
int ix_aes256_gcm_seal(const uint8_t key[32], const uint8_t nonce[12],
                       const uint8_t *plain, size_t plain_len,
                       uint8_t *combined, size_t *combined_len);

/// X25519. secret is 32 random bytes. shared is the raw agreement output.
int ix_x25519_public(uint8_t pub[32], const uint8_t secret[32]);
int ix_x25519_shared(uint8_t shared[32], const uint8_t secret[32], const uint8_t peer[32]);

/// RFC 8032 Ed25519. Returns 0 when the signature matches.
int ix_ed25519_verify(const uint8_t sig[64], const uint8_t pk[32],
                      const uint8_t *msg, size_t len);
int ix_ed25519_keypair(uint8_t secret[64], uint8_t pub[32], const uint8_t seed[32]);
int ix_ed25519_sign(uint8_t sig[64], const uint8_t secret[64],
                    const uint8_t *msg, size_t len);

/// Open a server VPN box. info is igx-vpn-v1. Returns 0 on success.
int ix_vpn_open(const uint8_t secret[32], const uint8_t epk[32], const uint8_t salt[32],
                const uint8_t *box, size_t box_len, uint8_t *plain, size_t *plain_len);

#ifdef __cplusplus
}
#endif

#endif
