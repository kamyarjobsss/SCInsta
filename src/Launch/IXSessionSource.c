#include "IXSessionSource.h"

#include <stdio.h>
#include <string.h>

static const char *ix_groups[] = {
    "group.com.burbn.instagram",
    "group.com.facebook.family",
    "group.com.burbn.family"
};

const char *IXSessionGroupIdentifier(int index) {
    if (index < 0 || index >= 3) return NULL;
    return ix_groups[index];
}

static int ix_lower(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A' + 'a';
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

static int ix_dir(const char *path, const char *dir) {
    size_t n = strlen(dir);
    const char *p = path;
    if (n == 0) return 0;
    while ((p = strstr(p, dir)) != NULL) {
        int before = (p == path) || p[-1] == '/';
        int after = p[n] == '/' || p[n] == '\0';
        if (before && after) return 1;
        p += n;
    }
    return 0;
}

int IXSessionPathClass(const char *path) {
    if (!path || !path[0]) return IX_PATH_MISSING;
    if (ix_dir(path, "Documents")) return IX_PATH_DOCUMENTS;
    if (ix_dir(path, "Shared") || ix_dir(path, "AppGroup") || ix_dir(path, "Group Containers")) return IX_PATH_SYSTEM;
    return IX_PATH_OTHER;
}

const char *IXSessionPathClassName(int klass) {
    if (klass == IX_PATH_DOCUMENTS) return "documents";
    if (klass == IX_PATH_SYSTEM) return "system";
    if (klass == IX_PATH_OTHER) return "other";
    return "missing";
}

static int ix_token(const char *text, size_t max, int allow_eq) {
    size_t n, i;
    if (!text || !text[0]) return 0;
    n = strlen(text);
    if (n > max) return 0;
    for (i = 0; i < n; i++) {
        char c = text[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (allow_eq && c == '=') ok = 1;
        if (!ok) return 0;
    }
    if (ix_has(text, "sessionid") || ix_has(text, "password")) return 0;
    return 1;
}

int IXSessionSourceLine(const char *phase, const char *kind, const char *name,
                        int present, unsigned long long bytes, const char *detail,
                        char *out, size_t outLen) {
    int wrote;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (present != 0 && present != 1) return 0;
    if (!ix_token(phase, 32, 0) || !ix_token(kind, 32, 0) || !ix_token(name, 96, 0)) return 0;
    if (!detail || !detail[0]) detail = "-";
    if (!ix_token(detail, 64, 1)) return 0;
    wrote = snprintf(out, outLen,
                     "source phase=%s kind=%s name=%s present=%d bytes=%llu detail=%s",
                     phase, kind, name, present, bytes, detail);
    if (wrote < 0 || (size_t)wrote >= outLen) {
        out[0] = 0;
        return 0;
    }
    return 1;
}

int IXSessionCookieLogName(const char *cookie, char *out, size_t outLen) {
    const char *log = NULL;
    size_t n;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!cookie || !cookie[0]) return 0;
    if (strcmp(cookie, "sessionid") == 0) log = "session_cookie";
    else if (strcmp(cookie, "ds_user_id") == 0) log = "ds_user";
    else if (strcmp(cookie, "csrftoken") == 0) log = "csrf";
    else if (strcmp(cookie, "mid") == 0) log = "mid";
    else if (strcmp(cookie, "rur") == 0) log = "rur";
    if (!log) return 0;
    n = strlen(log);
    if (n + 1 > outLen) return 0;
    memcpy(out, log, n + 1);
    return 1;
}

static int ix_digit_run(const char *text) {
    int run = 0;
    int best = 0;
    for (; *text; text++) {
        if (*text >= '0' && *text <= '9') {
            run++;
            if (run > best) best = run;
        } else {
            run = 0;
        }
    }
    return best;
}

int IXSessionArchiveName(const char *name) {
    if (!name || !name[0] || strlen(name) > 80) return 0;
    if (strchr(name, '/') || strchr(name, '\\') || strstr(name, "..")) return 0;
    if (ix_digit_run(name) >= 6) return 0;
    if (ix_has(name, "password") || ix_has(name, "sessionid")) return 0;
    if (strcmp(name, "server_save_status.plist") == 0) return 1;
    if (strcmp(name, "save_expiration.plist") == 0) return 1;
    if (strstr(name, "AuthenticatedUser") || strstr(name, "UserSession") ||
        strstr(name, "persistAuthenticated")) return 1;
    return 0;
}

int IXSessionArchiveLogName(const char *name, char *out, size_t outLen) {
    const char *log = NULL;
    size_t n;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!IXSessionArchiveName(name)) return 0;
    if (strcmp(name, "server_save_status.plist") == 0) log = "server_save_status.plist";
    else if (strcmp(name, "save_expiration.plist") == 0) log = "save_expiration.plist";
    else if (strstr(name, "persistAuthenticated")) log = "persist_users";
    else if (strstr(name, "AuthenticatedUser")) log = "authenticated_user";
    else if (strstr(name, "UserSession")) log = "user_session";
    if (!log) return 0;
    n = strlen(log);
    if (n + 1 > outLen) return 0;
    memcpy(out, log, n + 1);
    return 1;
}

int IXSessionScanDirectory(const char *name) {
    if (!name || !name[0] || strlen(name) > 180) return 0;
    if (strchr(name, '/') || strchr(name, '\\') || strstr(name, "..")) return 0;
    if (ix_digit_run(name) >= 6) return 0;
    if (strcmp(name, "Library") == 0 || strcmp(name, "Preferences") == 0 ||
        strcmp(name, "Cookies") == 0 || strcmp(name, "mobileconfig") == 0 ||
        strcmp(name, "InstagramX") == 0 || strcmp(name, "IXAppGroup") == 0 ||
        strcmp(name, "Application Support") == 0) return 1;
    if (strncmp(name, "group.com.", 10) == 0) return 1;
    return 0;
}

int IXSessionRedactDigits(const char *text, char *out, size_t outLen) {
    size_t w = 0;
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!text) return 0;
    while (*text) {
        if (*text >= '0' && *text <= '9') {
            int run = 0;
            while (text[run] >= '0' && text[run] <= '9') run++;
            if (run >= 6) {
                if (w + 1 >= outLen) {
                    out[0] = 0;
                    return 0;
                }
                out[w++] = '#';
                text += run;
                continue;
            }
        }
        if (w + 1 >= outLen) {
            out[0] = 0;
            return 0;
        }
        out[w++] = *text++;
    }
    out[w] = 0;
    return 1;
}
