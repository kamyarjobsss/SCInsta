#include <stdio.h>
#include <string.h>

#include "../src/Launch/IXSessionLaunch.h"
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
    expect(IXSessionSeedFresh(1, 1, 0) == 1, "existing install with cookies and no marker is seeded");
    expect(IXSessionSeedFresh(1, 0, 0) == 1, "seen launch with no marker is seeded");
    expect(IXSessionSeedFresh(0, 1, 0) == 1, "cookie file alone means the install is not new");
    expect(IXSessionSeedFresh(0, 0, 0) == 0, "first launch is not disguised");
    expect(IXSessionSeedFresh(1, 1, 1) == 0, "marker already on disk is not replaced");
    expect(IXSessionContainerLeaf("group.com.burbn.instagram", out, sizeof out) == 1, "base container leaf");
    expect_str(out, "group.com.burbn.instagram", "base leaf is the group id");
    expect(IXSessionContainerLeaf(NULL, out, sizeof out) == 1, "null base leaf");
    expect_str(out, "group.com.burbn.instagram", "null base leaf default");
    expect(IXSessionContainerLeaf("a/b", out, sizeof out) == 0, "base leaf rejects a slash");
    expect(IXSessionContainerLeaf("..", out, sizeof out) == 0, "base leaf rejects dotdot");
    expect(IXSessionHoldCount(1, 0, 0, 0) == 1, "live account is reported");
    expect(IXSessionHoldCount(0, 1, 1, 0) == 1, "cookie keeps the saved account");
    expect(IXSessionHoldCount(0, 1, 0, 1) == 1, "restore window keeps the saved account");
    expect(IXSessionHoldCount(0, 1, 0, 0) == 0, "logout after the window reports zero");
    expect(IXSessionHoldCount(0, 0, 1, 1) == 0, "nothing saved stays zero");
    expect(IXSessionReportAccounts(2, 0, 0, 0) == 1, "live harvest is sent");
    expect(IXSessionReportAccounts(0, 1, 1, 0) == 2, "saved list is sent while the cookie remains");
    expect(IXSessionReportAccounts(0, 1, 0, 1) == 2, "saved list is sent during the restore window");
    expect(IXSessionReportAccounts(0, 0, 1, 0) == -1, "cookie without a saved list does not send zero");
    expect(IXSessionReportAccounts(0, 0, 0, 1) == -1, "restore window without a saved list does not send zero");
    expect(IXSessionReportAccounts(0, 1, 0, 0) == 0, "logout sends zero");
    expect(IXSessionReportAccounts(0, 0, 0, 0) == 0, "confirmed empty sends zero");
    expect(IXSessionRewriteGroup("group.com.facebook.family", "773S3XDQX7.com.burbn.instagram") == 1, "family group is rewritten");
    expect(IXSessionRewriteGroup(NULL, "773S3XDQX7.com.burbn.instagram") == 1, "missing group is rewritten");
    expect(IXSessionRewriteGroup("", "773S3XDQX7.com.burbn.instagram") == 1, "empty group is rewritten");
    expect(IXSessionRewriteGroup("773S3XDQX7.com.burbn.instagram", "773S3XDQX7.com.burbn.instagram") == 0, "entitled group stays");
    expect(IXSessionRewriteGroup("group.com.facebook.family", NULL) == 0, "no entitled group means no rewrite");
    expect(IXSessionRewriteGroup("group.com.facebook.family", "") == 0, "blank entitled group means no rewrite");
    expect(IXSessionPersistSuite("group.com.burbn.instagram") == 1, "ig group suite persists");
    expect(IXSessionPersistSuite("group.com.facebook.family") == 1, "family group suite persists");
    expect(IXSessionPersistSuite("group.com.burbn.family") == 1, "burbn family suite persists");
    expect(IXSessionPersistSuite("com.burbn.instagram") == 0, "app domain is not a group suite");
    expect(IXSessionPersistSuite("instagramx.vpn") == 0, "our suite is not a group suite");
    expect(IXSessionPersistSuite(NULL) == 0, "null suite is not persisted");
    expect(IXSessionPersistSuite("") == 0, "empty suite is not persisted");
    expect(IXSessionPersistSuite("group.com.burbn.instagram/../x") == 0, "suite slash is rejected");
    expect(IXSessionPersistSuite("group.com/..") == 0, "suite dotdot is rejected");
    expect(IXSessionSuitePlist("/docs", "group.com.burbn.instagram", out, sizeof out) == 1, "suite plist path");
    expect_str(out, "/docs/group.com.burbn.instagram/Library/Preferences/group.com.burbn.instagram.plist", "suite plist value");
    expect(IXSessionSuitePlist("/docs", "group.com.facebook.family", out, sizeof out) == 1, "family plist path");
    expect(IXSessionSuitePlist("/docs", "com.burbn.instagram", out, sizeof out) == 0, "app domain has no suite plist");
    expect(IXSessionSuitePlist(NULL, "group.com.burbn.instagram", out, sizeof out) == 0, "null docs");
    expect(IXSessionSuitePlist("/docs", "group.com.burbn.instagram", out, 8) == 0, "short suite plist");
    IXSessionLaunchReset();
    IXSessionLaunchNoteImage("/usr/lib/libSystem.B.dylib");
    expect(IXSessionLaunchMayWalkClasses() == 0, "class walk waits for the framework");
    IXSessionLaunchNoteImage("Payload/Instagram.app/Frameworks/FBSharedFramework");
    expect(IXSessionLaunchMayWalkClasses() == 1, "class walk after framework");
    IXSessionLaunchNoteImage("libobjc.A.dylib");
    expect(IXSessionLaunchMayWalkClasses() == 1, "later images stay ready");
    IXSessionLaunchReset();
    expect(IXSessionLaunchMayWalkClasses() == 0, "reset refuses the class walk");
    expect(IXSessionContainerLeaf("a\\b", out, sizeof out) == 0, "base leaf rejects a backslash");
    expect(IXSessionSensitiveName("sessionid") == 1, "session name");
    expect(IXSessionSensitiveName("Library/Cookies/Cookies.binarycookies") == 1, "cookie path");
    expect(IXSessionSensitiveName("mc_freshinstall_time") == 1, "fresh marker name");
    expect(IXSessionSensitiveName("password") == 0, "password name is not recorded");
    expect(IXSessionSensitiveName("theme_force_dark") == 0, "unrelated name");

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

    expect(IXSessionFrameworkName("FBSharedFramework") == 1, "framework basename");
    expect(IXSessionFrameworkName("/path/FBSharedFramework") == 1, "framework path");
    expect(IXSessionFrameworkName("SCInsta.dylib") == 0, "tweak is not the framework");
    expect(IXSessionFrameworkName(NULL) == 0, "null framework");

    expect(IXSessionUseDocumentsContainer("group.com.burbn.instagram") == 1, "ig container ignores a system url");
    expect(IXSessionUseDocumentsContainer("group.com.facebook.family") == 1, "family container ignores a system url");
    expect(IXSessionUseDocumentsContainer("group.com.burbn.family") == 1, "burbn container ignores a system url");
    expect(IXSessionUseDocumentsContainer("group.com.burbn.instagram.TEAM") == 1, "suffixed ig container");
    expect(IXSessionUseDocumentsContainer("group.com.facebook.familyextra") == 0, "family prefix needs a boundary");
    expect(IXSessionUseDocumentsContainer("group.com.other") == 0, "other group stays with the system");
    expect(IXSessionUseDocumentsContainer("com.burbn.instagram") == 0, "app domain is not a group container");
    expect(IXSessionDocumentsContainer("/docs", "group.com.burbn.instagram", out, sizeof out) == 1, "documents container");
    expect_str(out, "/docs/group.com.burbn.instagram", "documents container path");
    expect(IXSessionDocumentsContainer("/docs", "com.burbn.instagram", out, sizeof out) == 0, "app id has no documents container");

    expect(IXSessionStoredAccessGroup("group.com.facebook.family", "PROBEGROUP", out, sizeof out) == 1, "auth group uses the probe");
    expect_str(out, "PROBEGROUP", "probe group is not the requested group");
    expect(IXSessionStoredAccessGroup("PROBEGROUP", "PROBEGROUP", out, sizeof out) == 1, "matching probe stays");
    expect_str(out, "PROBEGROUP", "matching probe value");
    expect(IXSessionStoredAccessGroup("group.com.burbn.instagram", "", out, sizeof out) == 0, "empty probe is not invented");
    expect(IXSessionStoredAccessGroup("group.com.burbn.instagram", NULL, out, sizeof out) == 0, "null probe is not invented");
    expect(IXSessionAuthStorePath("/docs", "PROBEGROUP", out, sizeof out) == 1, "authheaders path");
    expect_str(out, "/docs/InstagramX/session-sim/PROBEGROUP/authheaders", "authheaders path value");
    expect(IXSessionAuthStorePath("/docs", "a/b", out, sizeof out) == 0, "authheaders slash rejected");
    expect(IXSessionSharedSessionPath("/docs", out, sizeof out) == 1, "shared session path");
    expect_str(out, "/docs/InstagramX/session-sim/shared-session", "shared session path value");

    expect(IXSessionFirstInstall(0, 0) == 1, "no marker is a first install");
    expect(IXSessionFirstInstall(1, 0) == 0, "file marker is an existing install");
    expect(IXSessionFirstInstall(0, 1) == 0, "keychain marker survives a new container");
    expect(IXSessionStatePath("/home", "/home") == 1, "home is state");
    expect(IXSessionStatePath("/home", "/home/Documents") == 1, "documents root is state");
    expect(IXSessionStatePath("/home", "/home/Documents/group.com.burbn.instagram/Library/Preferences/x.plist") == 1, "group plist is state");
    expect(IXSessionStatePath("/home", "/home/Library/Preferences/com.burbn.instagram.plist") == 1, "app plist is state");
    expect(IXSessionStatePath("/home", "/home/Library/Cookies/Cookies.binarycookies") == 1, "cookie file is state");
    expect(IXSessionStatePath("/home", "/home/Library/Caches/image") == 0, "cache clear stays allowed");
    expect(IXSessionStatePath("/home", "/other/Documents") == 0, "outside home is not state");
    expect(IXSessionDomainWipe(NULL, "com.example.app") == 1, "empty domain is a wipe");
    expect(IXSessionDomainWipe("com.example.app", "com.example.app") == 1, "bundle domain is a wipe");
    expect(IXSessionDomainWipe("com.burbn.instagram", "com.example.app") == 1, "original bundle domain is a wipe");
    expect(IXSessionDomainWipe("group.com.facebook.family", "com.example.app") == 1, "group domain is a wipe");
    expect(IXSessionDomainWipe("instagramx.vpn", "com.example.app") == 0, "unrelated domain stays");
    expect(IXSessionKeepKey("mc_freshinstall_time") == 1, "fresh marker is kept");
    expect(IXSessionKeepKey("logged_in_user_id") == 1, "user id is kept");
    expect(IXSessionKeepKey("sci_exp_warning_seen") == 1, "tweak popup flag is kept");
    expect(IXSessionKeepKey("fake_location_enabled") == 0, "setting key is not frozen");
    expect(IXSessionBlockWipe(1, 1) == 0, "first install may wipe");
    expect(IXSessionBlockWipe(0, 1) == 1, "existing install blocks a state wipe");
    expect(IXSessionBlockWipe(0, 0) == 0, "existing install allows a cache delete");
    expect(IXSessionInstallMarkerPath("/docs", out, sizeof out) == 1, "install marker path");
    expect_str(out, "/docs/InstagramX/ix_install_marker", "install marker path value");
    expect(IXSessionKeptDefaultsPath("/docs", out, sizeof out) == 1, "kept defaults path");
    expect(IXSessionKeptDocumentPath("/docs", out, sizeof out) == 1, "kept document path");
    return g_failed ? 1 : 0;
}
