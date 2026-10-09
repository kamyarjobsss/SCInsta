#include <stdio.h>
#include <string.h>

#include "../src/Launch/IXSessionPersist.h"

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
    char out[256];
    expect(IXSessionProbedGroup("TEAMID1234.com.burbn.instagram", out, sizeof out) == 1, "probe set");
    expect_str(out, "TEAMID1234.com.burbn.instagram", "probe value");
    expect(IXSessionProbedGroup("", out, sizeof out) == 0, "empty probe");
    expect_str(out, "", "empty probe clears");
    expect(IXSessionProbedGroup(NULL, out, sizeof out) == 0, "null probe");

    expect(IXSessionContainerComponent("group.com.burbn.instagram", out, sizeof out) == 1, "bare container");
    expect_str(out, "group.com.burbn.instagram", "bare container value");
    expect(IXSessionContainerComponent("TEAMID1234.group.com.burbn.instagram", out, sizeof out) == 1, "prefixed container");
    expect_str(out, "TEAMID1234.group.com.burbn.instagram", "prefix is not stripped");
    expect(IXSessionContainerComponent(NULL, out, sizeof out) == 1, "null container");
    expect_str(out, "group.com.burbn.instagram", "null container default");
    expect(IXSessionContainerComponent("a/b", out, sizeof out) == 0, "slash rejected");
    expect(IXSessionProbedGroup("x", out, 1) == 0, "short buffer");

    expect(IXPrefsSharedSuite("group.com.burbn.instagram", out, sizeof out) == 1, "ig suite");
    expect_str(out, "instagramx.appgroup", "ig suite value");
    expect(IXPrefsSharedSuite("group.com.burbn.instagram.773S3XDQX7", out, sizeof out) == 1, "ig team suite");
    expect_str(out, "instagramx.appgroup", "ig team shares one store");
    expect(IXPrefsSharedSuite("group.com.facebook.family", out, sizeof out) == 1, "family suite");
    expect_str(out, "instagramx.appgroup", "family shares the ig store");
    expect(IXPrefsSharedSuite("instagramx.appgroup", out, sizeof out) == 0, "mapped name does not remap");
    expect(IXPrefsSharedSuite("instagramx.vpn", out, sizeof out) == 0, "vpn suite left alone");
    expect(IXPrefsSharedSuite("com.burbn.instagram", out, sizeof out) == 0, "app domain left alone");
    expect(IXPrefsSharedSuite(NULL, out, sizeof out) == 0, "null suite");
    expect(IXPrefsSharedSuite("group.com.burbn.instagram", out, 4) == 0, "short suite buffer");

    expect(IXKeychainReadFirstSync(IX_SYNC_ABSENT) == IX_SYNC_ANY, "omitted sync reads both");
    expect(IXKeychainReadFirstSync(IX_SYNC_FALSE) == IX_SYNC_FALSE, "explicit local stays");
    expect(IXKeychainReadFirstSync(IX_SYNC_TRUE) == IX_SYNC_TRUE, "explicit sync stays");
    expect(IXKeychainReadFirstSync(IX_SYNC_ANY) == IX_SYNC_ANY, "any stays");
    expect(IXKeychainReadFallbackSync(IX_SYNC_ABSENT, IX_KC_OK) == -1, "hit is final");
    expect(IXKeychainReadFallbackSync(IX_SYNC_ABSENT, IX_KC_MISSING_ENTITLEMENT) == IX_SYNC_ABSENT, "any entitlement falls back");
    expect(IXKeychainReadFallbackSync(IX_SYNC_FALSE, IX_KC_NOT_FOUND) == IX_SYNC_ANY, "local miss tries any");
    expect(IXKeychainReadFallbackSync(IX_SYNC_TRUE, IX_KC_NOT_FOUND) == IX_SYNC_ANY, "sync miss tries any");
    expect(IXKeychainReadFallbackSync(IX_SYNC_TRUE, IX_KC_MISSING_ENTITLEMENT) == IX_SYNC_ANY, "sync entitlement tries any");
    expect(IXKeychainReadFallbackSync(IX_SYNC_ANY, IX_KC_NOT_FOUND) == -1, "any miss does not loop");
    expect(IXKeychainReadFallbackSync(IX_SYNC_FALSE, -50) == -1, "other errors stand");

    expect(IXFreshInstallKey("mc_freshinstall_time") == 1, "time marker");
    expect(IXFreshInstallKey("mobileconfig_freshinstall_track_version") == 1, "version marker");
    expect(IXFreshInstallKey("MC_FRESHINSTALL_TIME") == 1, "marker case");
    expect(IXFreshInstallKey("session_freshinstall") == 0, "session key skipped");
    expect(IXFreshInstallKey("freshinstall_password") == 0, "password key skipped");
    expect(IXFreshInstallKey("freshinstall_token") == 0, "token key skipped");
    expect(IXFreshInstallKey("haslaunched") == 0, "other flag");
    expect(IXFreshInstallKey(NULL) == 0, "null marker");
    expect(IXFreshInstallKey("") == 0, "empty marker");
    expect(IXFreshKnownKey("mc_freshinstall_time") == 1, "known time");
    expect(IXFreshKnownKey("mobileconfig_freshinstall_track_version") == 1, "known version");
    expect(IXFreshKnownKey("other_freshinstall") == 0, "unknown fresh key is not a placeholder");
    expect(IXFreshKnownKey(NULL) == 0, "null known key");
    expect(IXFreshMarkerRestore(0, 1) == 1, "missing plist restores the saved marker");
    expect(IXFreshMarkerRestore(1, 1) == 0, "persisted marker is kept");
    expect(IXFreshMarkerRestore(0, 0) == 0, "nothing to restore");
    expect(IXFreshMarkerRestore(1, 0) == 0, "persisted only");
    expect(IXFreshMarkerSeed(0, 0, 1) == 1, "absent known marker is seeded");
    expect(IXFreshMarkerSeed(0, 1, 1) == 0, "saved marker is not replaced");
    expect(IXFreshMarkerSeed(1, 0, 1) == 0, "persisted marker is not replaced");
    expect(IXFreshMarkerSeed(0, 0, 0) == 0, "unknown key is not invented");

    expect(IXSessionOurService("instagramx.diag") == 1, "probe service");
    expect(IXSessionOurService("instagramx.backend") == 1, "backend service");
    expect(IXSessionOurService("instagramx.vpn") == 1, "vpn service");
    expect(IXSessionOurService("com.burbn.instagram") == 0, "instagram service is not ours");
    expect(IXSessionOurService(NULL) == 0, "missing service");
    expect(IXSessionPasswordClass("genp") == 1, "generic password");
    expect(IXSessionPasswordClass("inet") == 1, "internet password");
    expect(IXSessionPasswordClass("") == 1, "unscoped delete");
    expect(IXSessionPasswordClass(NULL) == 1, "missing class");
    expect(IXSessionPasswordClass("cert") == 0, "certificate");
    expect(IXSessionPasswordClass("key") == 0, "key class");
    expect(IXSessionPasswordClass("idnt") == 0, "identity");

    /* v2.4.2 second launch: ix_seen_launch=existing, both preference plists
       absent, accounts already 0 when didFinishLaunching returned. v2.4.1
       logged SecItemDelete status 0 with an access group in the query, and
       the instagramx.diag probe was still there afterward. */
    expect(IXSessionDeleteAllowed(1, 0, 0, 0, 1) == 0, "relaunch password delete is refused");
    expect(IXSessionDeleteAllowed(1, 0, 0, IXSessionOurService("instagramx.diag"), 1) == 1, "probe delete stays allowed");
    expect(IXSessionDeleteAllowed(1, 1, 0, 0, 1) == 1, "logout after launch is allowed");
    expect(IXSessionDeleteAllowed(0, 0, 0, 0, 1) == 1, "first install delete is allowed");
    expect(IXSessionDeleteAllowed(1, 0, 0, 0, 0) == 1, "certificate delete is allowed");
    expect(IXSessionDeleteAllowed(1, 0, 0, 0, IXSessionPasswordClass(NULL)) == 0, "unscoped relaunch wipe is refused");
    expect(IXSessionDeleteAllowed(1, 0, 1, 0, 1) == 1, "stored marker allows a launch delete");

    /* v2.2.4 kept the login. e0b8495 (2.3.0) gave each group its own
       directory, stored the requested name instead of the probed keychain
       group, and rewrote a non-empty identifier. */
    expect(IXSessionFallbackLeaf("group.com.burbn.instagram", out, sizeof out) == 1, "fallback leaf");
    expect_str(out, "IXAppGroup", "one directory for the ig group");
    expect(IXSessionFallbackLeaf("TEAMID1234.group.com.burbn.instagram", out, sizeof out) == 1, "prefixed fallback");
    expect_str(out, "IXAppGroup", "prefix does not move the directory");
    expect(IXSessionFallbackLeaf(NULL, out, sizeof out) == 1, "null fallback");
    expect_str(out, "IXAppGroup", "null identifier shares the directory");
    expect(IXSessionDefaultsSuite("TEAMID1234.group.com.burbn.instagram", out, sizeof out) == 1, "defaults suite");
    expect_str(out, "group.com.burbn.instagram", "suite is not the identifier");
    expect(IXSessionDefaultsSuite(NULL, out, sizeof out) == 1, "null suite");
    expect_str(out, "group.com.burbn.instagram", "null suite value");
    expect(IXSessionIdentifierFill("group.com.burbn.instagram", "other", "TEAMID.com.burbn.instagram", out, sizeof out) == 0, "existing identifier stays");
    expect_str(out, "", "existing identifier is not rewritten");
    expect(IXSessionIdentifierFill("", "group.com.burbn.instagram", "TEAMID.com.burbn.instagram", out, sizeof out) == 1, "nil identifier uses the probe");
    expect_str(out, "TEAMID.com.burbn.instagram", "probe group is stored");
    expect(IXSessionIdentifierFill(NULL, "group.com.facebook.family", NULL, out, sizeof out) == 1, "nil identifier without a probe");
    expect_str(out, "group.com.facebook.family", "requested name is the fallback");
    expect(IXSessionIdentifierFill(NULL, NULL, NULL, out, sizeof out) == 1, "nil identifier default");
    expect_str(out, "group.com.burbn.instagram", "default identifier");
    return g_failed ? 1 : 0;
}
