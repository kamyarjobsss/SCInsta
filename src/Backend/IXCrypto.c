#include "IXCrypto.h"

#include "third_party/aes.h"
#include "third_party/monocypher-ed25519.h"
#include "third_party/monocypher.h"

#include <stdlib.h>
#include <string.h>

static uint32_t ix_rotr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }

static void ix_sha256_block(uint32_t s[8], const uint8_t block[64]) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    };
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ix_rotr(w[i - 15], 7) ^ ix_rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ix_rotr(w[i - 2], 17) ^ ix_rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = s[0], b = s[1], c = s[2], d = s[3], e = s[4], f = s[5], g = s[6], h = s[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ix_rotr(e, 6) ^ ix_rotr(e, 11) ^ ix_rotr(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + k[i] + w[i];
        uint32_t S0 = ix_rotr(a, 2) ^ ix_rotr(a, 13) ^ ix_rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    s[0] += a;
    s[1] += b;
    s[2] += c;
    s[3] += d;
    s[4] += e;
    s[5] += f;
    s[6] += g;
    s[7] += h;
}

int ix_sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
    uint32_t s[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint8_t block[64];
    size_t off = 0;
    while (len - off >= 64) {
        ix_sha256_block(s, data + off);
        off += 64;
    }
    size_t rem = len - off;
    memset(block, 0, 64);
    if (rem) memcpy(block, data + off, rem);
    block[rem] = 0x80;
    if (rem >= 56) {
        ix_sha256_block(s, block);
        memset(block, 0, 64);
    }
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++) block[63 - i] = (uint8_t)(bits >> (8 * i));
    ix_sha256_block(s, block);
    for (int i = 0; i < 8; i++) {
        out[i * 4] = (uint8_t)(s[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(s[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(s[i] >> 8);
        out[i * 4 + 3] = (uint8_t)s[i];
    }
    return 0;
}

static void ix_hmac_sha256(const uint8_t *key, size_t key_len,
                           const uint8_t *msg, size_t msg_len, uint8_t out[32]) {
    uint8_t k[64];
    memset(k, 0, 64);
    if (key_len > 64) ix_sha256(key, key_len, k);
    else if (key && key_len) memcpy(k, key, key_len);
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) {
        ipad[i] = (uint8_t)(k[i] ^ 0x36);
        opad[i] = (uint8_t)(k[i] ^ 0x5c);
    }
    uint8_t inner[32];
    size_t total = 64 + msg_len;
    uint8_t *buf = total <= 4096 ? NULL : NULL;
    uint8_t stack[4096];
    uint8_t *block;
    if (total <= sizeof(stack)) block = stack;
    else {
        block = (uint8_t *)malloc(total);
        buf = block;
    }
    if (!block) {
        memset(out, 0, 32);
        return;
    }
    memcpy(block, ipad, 64);
    if (msg_len && msg) memcpy(block + 64, msg, msg_len);
    ix_sha256(block, total, inner);
    memcpy(block, opad, 64);
    memcpy(block + 64, inner, 32);
    ix_sha256(block, 96, out);
    if (buf) free(buf);
    crypto_wipe(k, sizeof(k));
    crypto_wipe(inner, sizeof(inner));
}

int ix_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                   const uint8_t *salt, size_t salt_len,
                   const uint8_t *info, size_t info_len,
                   uint8_t *okm, size_t okm_len) {
    if (!okm || okm_len == 0 || okm_len > 255 * 32) return -1;
    uint8_t zeros[32];
    memset(zeros, 0, sizeof(zeros));
    const uint8_t *salt_bytes = salt;
    size_t salt_n = salt_len;
    if (!salt || salt_len == 0) {
        salt_bytes = zeros;
        salt_n = 32;
    }
    uint8_t prk[32];
    ix_hmac_sha256(salt_bytes, salt_n, ikm, ikm_len, prk);
    uint8_t prev[32];
    size_t prev_len = 0;
    size_t done = 0;
    uint8_t counter = 1;
    while (done < okm_len) {
        uint8_t msg[32 + 1024 + 1];
        if (info_len > 1024) return -1;
        size_t n = 0;
        if (prev_len) {
            memcpy(msg, prev, prev_len);
            n = prev_len;
        }
        if (info && info_len) {
            memcpy(msg + n, info, info_len);
            n += info_len;
        }
        msg[n++] = counter++;
        ix_hmac_sha256(prk, 32, msg, n, prev);
        prev_len = 32;
        size_t take = okm_len - done;
        if (take > 32) take = 32;
        memcpy(okm + done, prev, take);
        done += take;
    }
    crypto_wipe(prk, sizeof(prk));
    return 0;
}

static void ix_aes_block(const struct AES_ctx *ctx, const uint8_t in[16], uint8_t out[16]) {
    memcpy(out, in, 16);
    AES_ECB_encrypt(ctx, out);
}

static void ix_gf_mul(uint8_t x[16], const uint8_t h[16]) {
    uint8_t z[16];
    uint8_t v[16];
    memset(z, 0, 16);
    memcpy(v, h, 16);
    for (int i = 0; i < 16; i++) {
        for (int bit = 0; bit < 8; bit++) {
            if (x[i] & (uint8_t)(1u << (7 - bit))) {
                for (int k = 0; k < 16; k++) z[k] ^= v[k];
            }
            uint8_t lsb = (uint8_t)(v[15] & 1);
            for (int k = 15; k > 0; k--) v[k] = (uint8_t)((v[k] >> 1) | ((v[k - 1] & 1) << 7));
            v[0] = (uint8_t)(v[0] >> 1);
            if (lsb) v[0] ^= 0xe1;
        }
    }
    memcpy(x, z, 16);
}

static void ix_ghash(const uint8_t h[16], const uint8_t *ct, size_t ct_len, uint8_t out[16]) {
    uint8_t y[16];
    memset(y, 0, 16);
    size_t off = 0;
    while (off < ct_len) {
        uint8_t block[16];
        memset(block, 0, 16);
        size_t n = ct_len - off;
        if (n > 16) n = 16;
        memcpy(block, ct + off, n);
        for (int i = 0; i < 16; i++) y[i] ^= block[i];
        ix_gf_mul(y, h);
        off += n;
    }
    uint8_t lenb[16];
    memset(lenb, 0, 16);
    uint64_t cbits = (uint64_t)ct_len * 8;
    for (int i = 0; i < 8; i++) lenb[15 - i] = (uint8_t)(cbits >> (8 * i));
    for (int i = 0; i < 16; i++) y[i] ^= lenb[i];
    ix_gf_mul(y, h);
    memcpy(out, y, 16);
}

static void ix_ctr_xor(const struct AES_ctx *ctx, const uint8_t j0[16],
                       const uint8_t *in, size_t len, uint8_t *out) {
    uint8_t counter[16];
    memcpy(counter, j0, 16);
    uint32_t last = ((uint32_t)counter[12] << 24) | ((uint32_t)counter[13] << 16) |
                    ((uint32_t)counter[14] << 8) | (uint32_t)counter[15];
    last += 1;
    counter[12] = (uint8_t)(last >> 24);
    counter[13] = (uint8_t)(last >> 16);
    counter[14] = (uint8_t)(last >> 8);
    counter[15] = (uint8_t)last;
    size_t off = 0;
    while (off < len) {
        uint8_t stream[16];
        ix_aes_block(ctx, counter, stream);
        size_t n = len - off;
        if (n > 16) n = 16;
        for (size_t i = 0; i < n; i++) out[off + i] = (uint8_t)(in[off + i] ^ stream[i]);
        last = ((uint32_t)counter[12] << 24) | ((uint32_t)counter[13] << 16) |
               ((uint32_t)counter[14] << 8) | (uint32_t)counter[15];
        last += 1;
        counter[12] = (uint8_t)(last >> 24);
        counter[13] = (uint8_t)(last >> 16);
        counter[14] = (uint8_t)(last >> 8);
        counter[15] = (uint8_t)last;
        off += n;
    }
}

static int ix_tag_ok(const uint8_t a[16], const uint8_t b[16]) {
    uint8_t d = 0;
    for (int i = 0; i < 16; i++) d |= (uint8_t)(a[i] ^ b[i]);
    return d == 0;
}

int ix_aes256_gcm_seal(const uint8_t key[32], const uint8_t nonce[12],
                       const uint8_t *plain, size_t plain_len,
                       uint8_t *combined, size_t *combined_len) {
    if (!key || !nonce || !combined || !combined_len) return -1;
    if (plain_len && !plain) return -1;
    struct AES_ctx ctx;
    AES_init_ctx(&ctx, key);
    uint8_t h[16], j0[16];
    memset(h, 0, 16);
    ix_aes_block(&ctx, h, h);
    memset(j0, 0, 16);
    memcpy(j0, nonce, 12);
    j0[15] = 1;
    memcpy(combined, nonce, 12);
    ix_ctr_xor(&ctx, j0, plain, plain_len, combined + 12);
    uint8_t s[16], tag[16];
    ix_ghash(h, combined + 12, plain_len, s);
    uint8_t mask[16];
    ix_aes_block(&ctx, j0, mask);
    for (int i = 0; i < 16; i++) tag[i] = (uint8_t)(s[i] ^ mask[i]);
    memcpy(combined + 12 + plain_len, tag, 16);
    *combined_len = 12 + plain_len + 16;
    crypto_wipe(&ctx, sizeof(ctx));
    return 0;
}

int ix_aes256_gcm_open(const uint8_t key[32], const uint8_t *combined, size_t combined_len,
                       uint8_t *plain, size_t *plain_len) {
    if (!key || !combined || !plain || !plain_len || combined_len < 28) return -1;
    size_t ct_len = combined_len - 28;
    if (*plain_len < ct_len) return -1;
    struct AES_ctx ctx;
    AES_init_ctx(&ctx, key);
    uint8_t h[16], j0[16];
    memset(h, 0, 16);
    ix_aes_block(&ctx, h, h);
    memset(j0, 0, 16);
    memcpy(j0, combined, 12);
    j0[15] = 1;
    uint8_t s[16], expect[16], mask[16];
    ix_ghash(h, combined + 12, ct_len, s);
    ix_aes_block(&ctx, j0, mask);
    for (int i = 0; i < 16; i++) expect[i] = (uint8_t)(s[i] ^ mask[i]);
    if (!ix_tag_ok(expect, combined + 12 + ct_len)) {
        crypto_wipe(&ctx, sizeof(ctx));
        return -1;
    }
    ix_ctr_xor(&ctx, j0, combined + 12, ct_len, plain);
    *plain_len = ct_len;
    crypto_wipe(&ctx, sizeof(ctx));
    return 0;
}

int ix_x25519_public(uint8_t pub[32], const uint8_t secret[32]) {
    if (!pub || !secret) return -1;
    crypto_x25519_public_key(pub, secret);
    return 0;
}

int ix_x25519_shared(uint8_t shared[32], const uint8_t secret[32], const uint8_t peer[32]) {
    if (!shared || !secret || !peer) return -1;
    crypto_x25519(shared, secret, peer);
    return 0;
}

int ix_ed25519_verify(const uint8_t sig[64], const uint8_t pk[32],
                      const uint8_t *msg, size_t len) {
    if (!sig || !pk) return -1;
    return crypto_ed25519_check(sig, pk, msg, len);
}

int ix_ed25519_keypair(uint8_t secret[64], uint8_t pub[32], const uint8_t seed[32]) {
    if (!secret || !pub || !seed) return -1;
    uint8_t seed_copy[32];
    memcpy(seed_copy, seed, 32);
    crypto_ed25519_key_pair(secret, pub, seed_copy);
    crypto_wipe(seed_copy, 32);
    return 0;
}

int ix_ed25519_sign(uint8_t sig[64], const uint8_t secret[64],
                    const uint8_t *msg, size_t len) {
    if (!sig || !secret) return -1;
    crypto_ed25519_sign(sig, secret, msg, len);
    return 0;
}

int ix_vpn_open(const uint8_t secret[32], const uint8_t epk[32], const uint8_t salt[32],
                const uint8_t *box, size_t box_len, uint8_t *plain, size_t *plain_len) {
    if (!secret || !epk || !salt) return -1;
    uint8_t shared[32], key[32];
    ix_x25519_shared(shared, secret, epk);
    static const uint8_t info[] = "igx-vpn-v1";
    if (ix_hkdf_sha256(shared, 32, salt, 32, info, sizeof(info) - 1, key, 32) != 0) return -1;
    int rc = ix_aes256_gcm_open(key, box, box_len, plain, plain_len);
    crypto_wipe(shared, sizeof(shared));
    crypto_wipe(key, sizeof(key));
    return rc;
}
