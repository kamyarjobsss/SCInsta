#include "IXSessionPersist.h"

#include <stdio.h>
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

int IXSessionSeedFresh(int seen_launch, int cookie_file, int marker_on_disk) {
    if (marker_on_disk) return 0;
    if (seen_launch || cookie_file) return 1;
    return 0;
}

int IXSessionContainerLeaf(const char *identifier, char *out, size_t outLen) {
    const char *src = (identifier && identifier[0]) ? identifier : "group.com.burbn.instagram";
    if (strstr(src, "..") || strchr(src, '/') || strchr(src, '\\')) return 0;
    if (strlen(src) > 180) return 0;
    return ix_copy(out, outLen, src);
}

int IXSessionHoldCount(int harvested, int saved, int cookie_present, int within_restore_window) {
    if (harvested > 0) return harvested;
    if (saved > 0 && (cookie_present || within_restore_window)) return saved;
    return 0;
}

int IXSessionReportAccounts(int harvested, int saved, int cookie_present, int within_restore_window) {
    if (harvested > 0) return 1;
    if (saved > 0 && (cookie_present || within_restore_window)) return 2;
    if (cookie_present || within_restore_window) return -1;
    return 0;
}

int IXSessionRewriteGroup(const char *group, const char *entitled) {
    if (!entitled || !entitled[0]) return 0;
    if (group && group[0] && strcmp(group, entitled) == 0) return 0;
    return 1;
}

int IXSessionPersistSuite(const char *suite) {
    if (!suite || strncmp(suite, "group.", 6) != 0) return 0;
    if (strlen(suite) > 180) return 0;
    if (strchr(suite, '/') || strchr(suite, '\\') || strstr(suite, "..")) return 0;
    return 1;
}

int IXSessionSuitePlist(const char *docs, const char *suite, char *out, size_t outLen) {
    int wrote;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!docs || !docs[0] || strchr(docs, '\\') || !IXSessionPersistSuite(suite)) return 0;
    wrote = snprintf(out, outLen, "%s/%s/Library/Preferences/%s.plist", docs, suite, suite);
    if (wrote < 0 || (size_t)wrote >= outLen) {
        out[0] = 0;
        return 0;
    }
    return 1;
}

int IXSessionSensitiveName(const char *name) {
    if (!name || !name[0]) return 0;
    if (ix_has(name, "password")) return 0;
    return ix_has(name, "session") || ix_has(name, "auth") || ix_has(name, "account") ||
           ix_has(name, "cookie") || ix_has(name, "token") || ix_has(name, "device_id") ||
           ix_has(name, "ig_did") || ix_has(name, "phone_id") || ix_has(name, "guid") ||
           ix_has(name, "waterfall") || ix_has(name, "ds_user") || ix_has(name, "authorization") ||
           ix_has(name, "freshinstall") || ix_has(name, "ixappgroup") ||
           ix_has(name, "group.com.burbn") || ix_has(name, "group.com.facebook");
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

static int ix_group_prefix(const char *text, const char *prefix) {
    size_t n = strlen(prefix);
    if (strncmp(text, prefix, n) != 0) return 0;
    return text[n] == '\0' || text[n] == '.';
}

static int ix_safe_component(const char *text) {
    if (!text || !text[0] || strlen(text) > 180) return 0;
    if (strchr(text, '/') || strchr(text, '\\') || strstr(text, "..")) return 0;
    return 1;
}

int IXSessionUseDocumentsContainer(const char *identifier) {
    if (!IXSessionPersistSuite(identifier)) return 0;
    return ix_group_prefix(identifier, "group.com.burbn.instagram") ||
           ix_group_prefix(identifier, "group.com.facebook.family") ||
           ix_group_prefix(identifier, "group.com.burbn.family");
}

int IXSessionDocumentsContainer(const char *docs, const char *identifier, char *out, size_t outLen) {
    int wrote;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!docs || !docs[0] || strchr(docs, '\\') || !IXSessionUseDocumentsContainer(identifier)) return 0;
    wrote = snprintf(out, outLen, "%s/%s", docs, identifier);
    if (wrote < 0 || (size_t)wrote >= outLen) {
        out[0] = 0;
        return 0;
    }
    return 1;
}

int IXSessionStoredAccessGroup(const char *requested, const char *probed, char *out, size_t outLen) {
    (void)requested;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!probed || !probed[0]) return 0;
    return ix_copy(out, outLen, probed);
}

int IXSessionAuthStorePath(const char *docs, const char *probed, char *out, size_t outLen) {
    int wrote;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!docs || !docs[0] || strchr(docs, '\\') || !ix_safe_component(probed)) return 0;
    wrote = snprintf(out, outLen, "%s/InstagramX/session-sim/%s/authheaders", docs, probed);
    if (wrote < 0 || (size_t)wrote >= outLen) {
        out[0] = 0;
        return 0;
    }
    return 1;
}

int IXSessionSharedSessionPath(const char *docs, char *out, size_t outLen) {
    int wrote;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!docs || !docs[0] || strchr(docs, '\\')) return 0;
    wrote = snprintf(out, outLen, "%s/InstagramX/session-sim/shared-session", docs);
    if (wrote < 0 || (size_t)wrote >= outLen) {
        out[0] = 0;
        return 0;
    }
    return 1;
}

int IXSessionFirstInstall(int file_marker, int keychain_marker) {
    return (file_marker || keychain_marker) ? 0 : 1;
}

static int ix_under(const char *rel, const char *prefix) {
    size_t n = strlen(prefix);
    if (strncmp(rel, prefix, n) != 0) return 0;
    return rel[n] == '\0' || rel[n] == '/';
}

int IXSessionStatePath(const char *home, const char *path) {
    size_t h;
    const char *rel;
    if (!home || !home[0] || !path || !path[0]) return 0;
    h = strlen(home);
    if (strncmp(path, home, h) != 0) return 0;
    if (path[h] != '\0' && path[h] != '/') return 0;
    rel = path + h;
    if (*rel == '/') rel++;
    if (*rel == '\0') return 1;
    if (ix_under(rel, "Documents")) return 1;
    if (strcmp(rel, "Library") == 0) return 1;
    if (ix_under(rel, "Library/Preferences")) return 1;
    if (ix_under(rel, "Library/Cookies")) return 1;
    return 0;
}

int IXSessionDomainWipe(const char *domain, const char *bundle) {
    if (!domain || !domain[0]) return 1;
    if (strncmp(domain, "group.", 6) == 0) return 1;
    if (bundle && bundle[0] && strcmp(domain, bundle) == 0) return 1;
    if (strcmp(domain, "com.burbn.instagram") == 0) return 1;
    return 0;
}

int IXSessionKeepKey(const char *key) {
    if (!key || !key[0]) return 0;
    return strcmp(key, "mc_freshinstall_time") == 0 ||
           strcmp(key, "mobileconfig_freshinstall_track_version") == 0 ||
           strcmp(key, "logged_in_user_id") == 0 ||
           strcmp(key, "logged_in_user") == 0 ||
           strcmp(key, "logged_in_user_ids") == 0 ||
           strcmp(key, "sci_exp_warning_seen") == 0 ||
           strcmp(key, "sci_changelog_last_seen_version") == 0;
}

int IXSessionBlockWipe(int first_install, int state_target) {
    if (first_install) return 0;
    return state_target ? 1 : 0;
}

static int ix_marker_file(const char *docs, const char *name, char *out, size_t outLen) {
    int wrote;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!docs || !docs[0] || strchr(docs, '\\') || !ix_safe_component(name)) return 0;
    wrote = snprintf(out, outLen, "%s/InstagramX/%s", docs, name);
    if (wrote < 0 || (size_t)wrote >= outLen) {
        out[0] = 0;
        return 0;
    }
    return 1;
}

int IXSessionInstallMarkerPath(const char *docs, char *out, size_t outLen) {
    return ix_marker_file(docs, "ix_install_marker", out, outLen);
}

int IXSessionKeptDefaultsPath(const char *docs, char *out, size_t outLen) {
    return ix_marker_file(docs, "kept-defaults", out, outLen);
}

int IXSessionKeptDocumentPath(const char *docs, char *out, size_t outLen) {
    return ix_marker_file(docs, "kept-document", out, outLen);
}

int IXSessionDeleteAllowed(int existing_install, int launch_finished, int marker_persisted, int our_service, int password_class) {
    if (our_service) return 1;
    if (!password_class) return 1;
    if (existing_install && !launch_finished && !marker_persisted) return 0;
    return 1;
}
