#include "IXKeychainGroup.h"

#include <stdio.h>
#include <string.h>

static int ix_alnum(char c) {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

static int ix_copy(char *out, size_t outLen, const char *value) {
    if (!out || outLen == 0 || !value) return 0;
    size_t n = strlen(value);
    if (n + 1 > outLen) return 0;
    memcpy(out, value, n + 1);
    return 1;
}

int IXKeychainTeamPrefix(const char *applicationIdentifier, char prefix[11]) {
    if (!applicationIdentifier || !prefix) return 0;
    for (int i = 0; i < 10; i++) {
        if (!ix_alnum(applicationIdentifier[i])) return 0;
    }
    if (applicationIdentifier[10] != '.') return 0;
    memcpy(prefix, applicationIdentifier, 10);
    prefix[10] = 0;
    return 1;
}

int IXKeychainStripTeamPrefix(const char *group, char *bare, size_t bareLen) {
    if (!group || !bare || bareLen == 0) return 0;
    char prefix[11];
    const char *src = group;
    if (IXKeychainTeamPrefix(group, prefix)) src = group + 11;
    return ix_copy(bare, bareLen, src);
}

static int ix_wild_matches(const char *wild, const char *group) {
    if (!wild || !group) return 0;
    if (strcmp(wild, "*") == 0) return 1;
    size_t n = strlen(wild);
    if (n < 3 || wild[n - 2] != '.' || wild[n - 1] != '*') return 0;
    return strncmp(group, wild, n - 1) == 0;
}

static int ix_group_allowed(const char *group, const char *const *entitled, int count) {
    if (!group || !group[0]) return 0;
    for (int i = 0; i < count; i++) {
        if (!entitled[i]) continue;
        if (strcmp(entitled[i], group) == 0) return 1;
        if (ix_wild_matches(entitled[i], group)) return 1;
    }
    return 0;
}

int IXKeychainCanonicalGroup(const char *applicationIdentifier,
                             const char *requested,
                             const char *const *entitled,
                             int entitledCount,
                             char *out,
                             size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (entitledCount < 0) entitledCount = 0;
    if (!entitled) entitledCount = 0;

    char prefix[11];
    int havePrefix = IXKeychainTeamPrefix(applicationIdentifier, prefix);

    if (!requested || !requested[0]) {
        if (applicationIdentifier && applicationIdentifier[0]) return ix_copy(out, outLen, applicationIdentifier);
        return 0;
    }

    if (entitledCount > 0 && ix_group_allowed(requested, entitled, entitledCount)) {
        return ix_copy(out, outLen, requested);
    }

    char bare[512];
    if (!IXKeychainStripTeamPrefix(requested, bare, sizeof bare) || !bare[0]) {
        return ix_copy(out, outLen, requested);
    }

    if (havePrefix && entitledCount > 0) {
        char candidate[640];
        int wrote = snprintf(candidate, sizeof candidate, "%s.%s", prefix, bare);
        if (wrote > 0 && (size_t)wrote < sizeof candidate && ix_group_allowed(candidate, entitled, entitledCount)) {
            return ix_copy(out, outLen, candidate);
        }
    }

    if (entitledCount > 0 && applicationIdentifier &&
        ix_group_allowed(applicationIdentifier, entitled, entitledCount)) {
        return ix_copy(out, outLen, applicationIdentifier);
    }

    if (entitledCount > 0) {
        for (int i = 0; i < entitledCount; i++) {
            const char *entry = entitled[i];
            if (!entry || !entry[0] || strcmp(entry, "*") == 0) continue;
            size_t n = strlen(entry);
            if (n >= 2 && entry[n - 2] == '.' && entry[n - 1] == '*') continue;
            return ix_copy(out, outLen, entry);
        }
    }

    return ix_copy(out, outLen, requested);
}

int IXKeychainStalePrefixedGroup(const char *applicationIdentifier,
                                 const char *identifier,
                                 const char *const *entitled,
                                 int entitledCount,
                                 char *out,
                                 size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (entitledCount < 0) entitledCount = 0;
    if (!entitled) entitledCount = 0;

    char signedPrefix[11];
    char oldPrefix[11];
    if (!IXKeychainTeamPrefix(applicationIdentifier, signedPrefix)) return 0;
    if (!identifier || !IXKeychainTeamPrefix(identifier, oldPrefix)) return 0;
    if (strcmp(oldPrefix, signedPrefix) == 0) return 0;

    char bare[512];
    if (!IXKeychainStripTeamPrefix(identifier, bare, sizeof bare) || !bare[0]) return 0;

    char candidate[640];
    int wrote = snprintf(candidate, sizeof candidate, "%s.%s", signedPrefix, bare);
    if (wrote <= 0 || (size_t)wrote >= sizeof candidate) return 0;
    if (entitledCount == 0 || !ix_group_allowed(candidate, entitled, entitledCount)) return 0;
    return ix_copy(out, outLen, candidate);
}
