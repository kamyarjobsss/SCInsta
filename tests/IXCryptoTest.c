#include "../src/Backend/IXCrypto.h"

#include <stdio.h>
#include <string.h>

static int fails;

static void expect(int cond, const char *name) {
    if (cond) {
        printf("ok %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    fails++;
}

static int hex_eq(const uint8_t *got, size_t n, const char *hex) {
    for (size_t i = 0; i < n; i++) {
        unsigned byte;
        if (sscanf(hex + i * 2, "%2x", &byte) != 1) return 0;
        if (got[i] != (uint8_t)byte) return 0;
    }
    return 1;
}

static void test_sha(void) {
    uint8_t out[32];
    ix_sha256((const uint8_t *)"abc", 3, out);
    expect(hex_eq(out, 32, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "sha256 abc");
    ix_sha256((const uint8_t *)"", 0, out);
    expect(hex_eq(out, 32, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), "sha256 empty");
}

static void test_hkdf(void) {
    uint8_t ikm[22];
    memset(ikm, 0x0b, 22);
    uint8_t salt[13];
    for (int i = 0; i < 13; i++) salt[i] = (uint8_t)i;
    uint8_t info[10];
    for (int i = 0; i < 10; i++) info[i] = (uint8_t)(0xf0 + i);
    uint8_t okm[42];
    expect(ix_hkdf_sha256(ikm, 22, salt, 13, info, 10, okm, 42) == 0, "hkdf call");
    expect(hex_eq(okm, 42, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"), "hkdf rfc5869");
}

static void test_gcm(void) {
    uint8_t key[32];
    memset(key, 0, 32);
    uint8_t nonce[12];
    memset(nonce, 0, 12);
    uint8_t combined[28];
    size_t clen = sizeof(combined);
    expect(ix_aes256_gcm_seal(key, nonce, NULL, 0, combined, &clen) == 0, "gcm seal empty");
    expect(clen == 28, "gcm empty length");
    expect(hex_eq(combined + 12, 16, "530f8afbc74536b9a963b4f1c4cb738b"), "gcm nist empty tag");
    uint8_t plain[8];
    size_t plen = sizeof(plain);
    expect(ix_aes256_gcm_open(key, combined, clen, plain, &plen) == 0 && plen == 0, "gcm open empty");
    combined[27] ^= 1;
    plen = sizeof(plain);
    expect(ix_aes256_gcm_open(key, combined, clen, plain, &plen) != 0, "gcm rejects bad tag");

    const uint8_t msg[] = "igx-vpn-v1";
    uint8_t box[12 + sizeof(msg) - 1 + 16];
    size_t blen = sizeof(box);
    memset(nonce, 0x11, 12);
    memset(key, 0x22, 32);
    expect(ix_aes256_gcm_seal(key, nonce, msg, sizeof(msg) - 1, box, &blen) == 0, "gcm seal text");
    uint8_t out[32];
    plen = sizeof(out);
    expect(ix_aes256_gcm_open(key, box, blen, out, &plen) == 0, "gcm open text");
    expect(plen == sizeof(msg) - 1 && memcmp(out, msg, plen) == 0, "gcm roundtrip");
}

static void test_curves(void) {
    static const uint8_t seed[32] = {
        0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
        0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60
    };
    uint8_t secret[64], pub[32], sig[64];
    expect(ix_ed25519_keypair(secret, pub, seed) == 0, "ed25519 keypair");
    expect(hex_eq(pub, 32, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"), "ed25519 rfc8032 pub");
    expect(ix_ed25519_sign(sig, secret, NULL, 0) == 0, "ed25519 sign");
    expect(hex_eq(sig, 64, "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"), "ed25519 rfc8032 sig");
    expect(ix_ed25519_verify(sig, pub, NULL, 0) == 0, "ed25519 verify");
    sig[0] ^= 1;
    expect(ix_ed25519_verify(sig, pub, NULL, 0) != 0, "ed25519 rejects");

    uint8_t a_sec[32], b_sec[32], a_pub[32], b_pub[32], ab[32], ba[32];
    for (int i = 0; i < 32; i++) {
        a_sec[i] = (uint8_t)(i + 1);
        b_sec[i] = (uint8_t)(255 - i);
    }
    ix_x25519_public(a_pub, a_sec);
    ix_x25519_public(b_pub, b_sec);
    ix_x25519_shared(ab, a_sec, b_pub);
    ix_x25519_shared(ba, b_sec, a_pub);
    expect(memcmp(ab, ba, 32) == 0, "x25519 agree");
    expect(memcmp(ab, a_sec, 32) != 0, "x25519 not identity");

    uint8_t salt[32];
    memset(salt, 7, 32);
    const uint8_t payload[] = "{\"items\":[]}";
    uint8_t box[12 + sizeof(payload) - 1 + 16];
    size_t blen = sizeof(box);
    uint8_t key[32];
    uint8_t shared[32];
    ix_x25519_shared(shared, a_sec, b_pub);
    static const uint8_t info[] = "igx-vpn-v1";
    ix_hkdf_sha256(shared, 32, salt, 32, info, sizeof(info) - 1, key, 32);
    uint8_t nonce[12];
    memset(nonce, 3, 12);
    ix_aes256_gcm_seal(key, nonce, payload, sizeof(payload) - 1, box, &blen);
    uint8_t opened[64];
    size_t olen = sizeof(opened);
    expect(ix_vpn_open(b_sec, a_pub, salt, box, blen, opened, &olen) == 0, "vpn open");
    expect(olen == sizeof(payload) - 1 && memcmp(opened, payload, olen) == 0, "vpn plaintext");
    box[blen - 1] ^= 4;
    olen = sizeof(opened);
    expect(ix_vpn_open(b_sec, a_pub, salt, box, blen, opened, &olen) != 0, "vpn rejects");
}

int main(void) {
    test_sha();
    test_hkdf();
    test_gcm();
    test_curves();
    if (fails) {
        printf("%d failed\n", fails);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
