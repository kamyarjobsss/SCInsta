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
