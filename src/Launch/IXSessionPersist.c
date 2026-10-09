#include "IXSessionPersist.h"

#include <string.h>

static int ix_copy(char *out, size_t outLen, const char *value) {
    if (!out || outLen == 0 || !value) return 0;
    size_t n = strlen(value);
    if (n == 0 || n + 1 > outLen) return 0;
    memcpy(out, value, n + 1);
    return 1;
}

int IXSessionProbedGroup(const char *probed, char *out, size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!probed || !probed[0]) return 0;
    return ix_copy(out, outLen, probed);
}

int IXSessionContainerComponent(const char *identifier, char *out, size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    const char *src = (identifier && identifier[0]) ? identifier : "group.com.burbn.instagram";
    if (strchr(src, '/') || strchr(src, '\\')) return 0;
    return ix_copy(out, outLen, src);
}

static int ix_has_prefix(const char *text, const char *prefix) {
    size_t n = strlen(prefix);
    return strncmp(text, prefix, n) == 0;
}

int IXPrefsSharedSuite(const char *suite, char *out, size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!suite || !suite[0]) return 0;
    if (!ix_has_prefix(suite, "group.com.burbn.instagram") &&
        !ix_has_prefix(suite, "group.com.facebook.family")) {
        return 0;
    }
    return ix_copy(out, outLen, "instagramx.appgroup");
}

int IXKeychainReadFirstSync(int incoming) {
    if (incoming == IX_SYNC_FALSE || incoming == IX_SYNC_TRUE || incoming == IX_SYNC_ANY) return incoming;
    return IX_SYNC_ANY;
}

int IXKeychainReadFallbackSync(int incoming, int status) {
    int first;
    if (status == IX_KC_OK) return -1;
    if (status != IX_KC_NOT_FOUND && status != IX_KC_MISSING_ENTITLEMENT) return -1;
    first = IXKeychainReadFirstSync(incoming);
    if (incoming == IX_SYNC_ABSENT && first == IX_SYNC_ANY) return IX_SYNC_ABSENT;
    if (first != IX_SYNC_ANY) return IX_SYNC_ANY;
    return -1;
}

static char ix_lower(char c) {
    if (c >= 'A' && c <= 'Z') return (char)(c - 'A' + 'a');
    return c;
}

static int ix_has(const char *text, const char *needle) {
    size_t n = strlen(needle);
    size_t t = strlen(text);
    size_t i, j;
    if (n == 0 || t < n) return 0;
    for (i = 0; i + n <= t; i++) {
        for (j = 0; j < n; j++) {
            if (ix_lower(text[i + j]) != needle[j]) break;
        }
        if (j == n) return 1;
    }
    return 0;
}

int IXFreshInstallKey(const char *key) {
    size_t n;
    if (!key || !key[0]) return 0;
    n = strlen(key);
    if (n == 0 || n > 80) return 0;
    if (ix_has(key, "password") || ix_has(key, "token") || ix_has(key, "session")) return 0;
    return ix_has(key, "freshinstall");
}

int IXFreshKnownKey(const char *key) {
    if (!key) return 0;
    return strcmp(key, "mc_freshinstall_time") == 0 ||
           strcmp(key, "mobileconfig_freshinstall_track_version") == 0;
}

int IXFreshMarkerRestore(int persistent_present, int saved_present) {
    return !persistent_present && saved_present;
}

int IXFreshMarkerSeed(int persistent_present, int saved_present, int known_key) {
    if (persistent_present || saved_present) return 0;
    return known_key ? 1 : 0;
}

int IXSessionOurService(const char *service) {
    if (!service || !service[0]) return 0;
    return strcmp(service, "instagramx.diag") == 0 ||
           strcmp(service, "instagramx.backend") == 0 ||
           strcmp(service, "instagramx.vpn") == 0;
}

int IXSessionPasswordClass(const char *cls) {
    if (!cls || !cls[0]) return 1;
    if (strcmp(cls, "genp") == 0 || strcmp(cls, "inet") == 0) return 1;
    return 0;
}

int IXSessionFallbackLeaf(const char *identifier, char *out, size_t outLen) {
    (void)identifier;
    return ix_copy(out, outLen, "IXAppGroup");
}

int IXSessionDefaultsSuite(const char *identifier, char *out, size_t outLen) {
    (void)identifier;
    return ix_copy(out, outLen, "group.com.burbn.instagram");
}

int IXSessionIdentifierFill(const char *current, const char *requested, const char *probe, char *out, size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (current && current[0]) return 0;
    if (probe && probe[0]) return ix_copy(out, outLen, probe);
    if (requested && requested[0]) return ix_copy(out, outLen, requested);
    return ix_copy(out, outLen, "group.com.burbn.instagram");
}

int IXSessionDeleteAllowed(int existing_install, int launch_finished, int marker_persisted, int our_service, int password_class) {
    if (our_service) return 1;
    if (!password_class) return 1;
    if (existing_install && !launch_finished && !marker_persisted) return 0;
    return 1;
}
