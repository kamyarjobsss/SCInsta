#include <stdio.h>
#include <string.h>

#include "../src/Launch/IXSessionSource.h"

static int g_failed = 0;

static void expect(int cond, const char *name) {
    if (cond) {
        printf("ok %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    g_failed++;
}

static void expect_str(const char *got, const char *want, const char *name) {
    expect(got && want && strcmp(got, want) == 0, name);
    if (got && want && strcmp(got, want) != 0) printf("  got [%s] want [%s]\n", got, want);
}

int main(void) {
    char line[256];
    char name[32];
    char redacted[64];

    expect_str(IXSessionGroupIdentifier(0), "group.com.burbn.instagram", "ig group");
    expect_str(IXSessionGroupIdentifier(1), "group.com.facebook.family", "family group");
    expect_str(IXSessionGroupIdentifier(2), "group.com.burbn.family", "burbn family group");
    expect(IXSessionGroupIdentifier(3) == NULL, "no fourth group");
    expect(IXSessionGroupIdentifier(-1) == NULL, "negative group");

    expect(IXSessionPathClass(NULL) == IX_PATH_MISSING, "nil path");
    expect(IXSessionPathClass("") == IX_PATH_MISSING, "empty path");
    expect(IXSessionPathClass("/var/mobile/Containers/Data/Application/ABC/Documents/group.com.burbn.instagram") == IX_PATH_DOCUMENTS, "documents container");
    expect(IXSessionPathClass("/private/var/mobile/Containers/Shared/AppGroup/UUID") == IX_PATH_SYSTEM, "system app group");
    expect(IXSessionPathClass("/private/var/mobile/Containers/Shared/AppGroup/UUID/Documents/x") == IX_PATH_DOCUMENTS, "documents wins");
    expect(IXSessionPathClass("/tmp/other") == IX_PATH_OTHER, "other path");
    expect(IXSessionPathClass("/Users/x/Library/Group Containers/group.com.burbn.instagram") == IX_PATH_SYSTEM, "group containers");
    expect_str(IXSessionPathClassName(IX_PATH_MISSING), "missing", "missing name");
    expect_str(IXSessionPathClassName(IX_PATH_DOCUMENTS), "documents", "documents name");
    expect_str(IXSessionPathClassName(IX_PATH_SYSTEM), "system", "system name");
    expect_str(IXSessionPathClassName(99), "missing", "unknown class");

    expect(IXSessionSourceLine("ctor", "container", "group.com.burbn.instagram", 0, 0, "missing", line, sizeof line) == 1, "missing line");
    expect_str(line, "source phase=ctor kind=container name=group.com.burbn.instagram present=0 bytes=0 detail=missing", "missing text");
    expect(IXSessionSourceLine("will_pre", "keychain", "authheaders", 1, 2, "st0.entitled", line, sizeof line) == 1, "keychain line");
    expect_str(line, "source phase=will_pre kind=keychain name=authheaders present=1 bytes=2 detail=st0.entitled", "keychain text");
    expect(IXSessionSourceLine("ctor", "cookie", "sessionid", 1, 0, "shared", line, sizeof line) == 0, "cookie value name rejected");
    expect(IXSessionSourceLine("ctor", "pref", "password", 1, 0, "set", line, sizeof line) == 0, "password name rejected");
    expect(IXSessionSourceLine("ctor", "suite", "group.com.burbn.instagram", 2, 0, "home", line, sizeof line) == 0, "present flag");
    expect(IXSessionSourceLine("ctor", "suite", "a/b", 1, 0, "home", line, sizeof line) == 0, "slash name rejected");
    expect(IXSessionSourceLine(NULL, "suite", "ig", 1, 0, "home", line, sizeof line) == 0, "nil phase");
    expect(line[0] == 0, "rejected line cleared");
    expect(IXSessionSourceLine("ctor", "suite", "ig", 1, 4, NULL, line, sizeof line) == 1, "nil detail");
    expect_str(line, "source phase=ctor kind=suite name=ig present=1 bytes=4 detail=-", "nil detail dash");
    expect(IXSessionSourceLine("ctor", "suite", "ig", 1, 4, "home", line, 8) == 0, "short line");

    expect(IXSessionCookieLogName("sessionid", name, sizeof name) == 1, "session cookie alias");
    expect_str(name, "session_cookie", "session cookie text");
    expect(IXSessionCookieLogName("ds_user_id", name, sizeof name) == 1, "ds user alias");
    expect_str(name, "ds_user", "ds user text");
    expect(IXSessionCookieLogName("csrftoken", name, sizeof name) == 1, "csrf alias");
    expect(IXSessionCookieLogName("mid", name, sizeof name) == 1, "mid alias");
    expect(IXSessionCookieLogName("rur", name, sizeof name) == 1, "rur alias");
    expect(IXSessionCookieLogName("sessionid_value", name, sizeof name) == 0, "unknown cookie");
    expect(name[0] == 0, "unknown cookie cleared");

    expect(IXSessionArchiveName("server_save_status.plist") == 1, "save status");
    expect(IXSessionArchiveName("save_expiration.plist") == 1, "save expiration");
    expect(IXSessionArchiveName("IGAuthenticatedUser.archive") == 1, "authenticated user");
    expect(IXSessionArchiveName("persistAuthenticatedUsers") == 1, "persist users");
    expect(IXSessionArchiveName("IGUserSession") == 1, "user session object");
    expect(IXSessionArchiveName("IGAuthenticatedUser-123456.archive") == 0, "digit run rejected");
    expect(IXSessionArchiveName("Library/IGUserSession") == 0, "archive slash rejected");
    expect(IXSessionArchiveName("sessionid.archive") == 0, "archive secret rejected");
    expect(IXSessionArchiveName("Cookies.binarycookies") == 0, "cookie file is not an archive");
    expect(IXSessionArchiveLogName("server_save_status.plist", name, sizeof name) == 1, "save status log");
    expect_str(name, "server_save_status.plist", "save status log text");
    expect(IXSessionArchiveLogName("IGAuthenticatedUser-alice.archive", name, sizeof name) == 1, "user archive alias");
    expect_str(name, "authenticated_user", "user archive hides the filename");
    expect(IXSessionArchiveLogName("persistAuthenticatedUsers", name, sizeof name) == 1, "persist alias");
    expect_str(name, "persist_users", "persist alias text");
    expect(IXSessionArchiveLogName("IGUserSession", name, sizeof name) == 1, "session object alias");
    expect_str(name, "user_session", "session object alias text");
    expect(IXSessionArchiveLogName("IGAuthenticatedUser-123456.archive", name, sizeof name) == 0, "digit archive has no log name");

    expect(IXSessionScanDirectory("Library") == 1, "scan library");
    expect(IXSessionScanDirectory("group.com.burbn.instagram") == 1, "scan group");
    expect(IXSessionScanDirectory("12345678") == 0, "scan digit rejected");
    expect(IXSessionScanDirectory("tmp") == 0, "scan other rejected");

    expect(IXSessionRedactDigits("/Documents/123456789/session", redacted, sizeof redacted) == 1, "redact");
    expect_str(redacted, "/Documents/#/session", "redact text");
    expect(IXSessionRedactDigits("id=12345", redacted, sizeof redacted) == 1, "short digits stay");
    expect_str(redacted, "id=12345", "short digits text");
    expect(IXSessionRedactDigits("abcdefghij", redacted, 4) == 0, "redact overflow");

    if (g_failed) {
        printf("%d failed\n", g_failed);
        return 1;
    }
    printf("ok session source\n");
    return 0;
}
