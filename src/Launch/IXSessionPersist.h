#ifndef IX_SESSION_PERSIST_H
#define IX_SESSION_PERSIST_H

#include <stddef.h>

// Access group forced onto every SecItem query.
// A non-empty probed group (the one SecItem itself assigned when no group
// was requested) is copied and the return value is 1: callers must set
// kSecAttrAccessGroup to that exact string on add, copy, update, and delete.
// An empty probe returns 0: callers must remove kSecAttrAccessGroup so the
// system default is used for both reads and writes. The caller's group is
// never kept, and a team id is never invented here.
int IXSessionProbedGroup(const char *probed, char *out, size_t outLen);

// Last path component for an app-group container. The identifier is copied
// unchanged, including a team prefix, so the directory does not move when
// the signed prefix is re-read. NULL or empty becomes group.com.burbn.instagram.
// Returns 0 when `out` is too small or the identifier contains a slash.
int IXSessionContainerComponent(const char *identifier, char *out, size_t outLen);

// Instagram's fresh-install markers live in several group suite names.
// Those names share one sandbox suite, instagramx.appgroup, because a
// sideload cannot persist real group.com.* plists. Returns 1 when `suite`
// is one of those names. Other suites, including instagramx.appgroup
// itself, return 0 so the mapping cannot recurse.
int IXPrefsSharedSuite(const char *suite, char *out, size_t outLen);

/* The iCloud-keychain read helpers below are not the relaunch fix.
   A sideload log mentioned synchronizable items only as a clue. v2.4.2
   still logged out with SecItem hooks off, and the probe item survived. */

/* How a SecItem read asked about iCloud keychain.
   ABSENT means the query omitted kSecAttrSynchronizable, which by default
   searches only the local partition and misses a synchronizable login item. */
#define IX_SYNC_ABSENT 0
#define IX_SYNC_FALSE 1
#define IX_SYNC_TRUE 2
#define IX_SYNC_ANY 3

#define IX_KC_OK 0
#define IX_KC_NOT_FOUND (-25300)
#define IX_KC_MISSING_ENTITLEMENT (-34018)

/* First synchronizable mode to use. An omitted attribute becomes Any so
   one read sees both partitions. An explicit true, false, or Any is kept. */
int IXKeychainReadFirstSync(int incoming);

/* Second mode after `status`, or -1 when the first result stands.
   Not-found and a missing iCloud entitlement try the other partition.
   Success is never repeated. */
int IXKeychainReadFallbackSync(int incoming, int status);

/* 1 when `key` is an Instagram fresh-install marker. Names that contain
   password, token, or session are rejected so this store cannot hold them.
   The match is ASCII case-insensitive. NULL and overlong names are 0. */
int IXFreshInstallKey(const char *key);

/* The two markers v2.4.2 printed while the preference plists were absent. */
int IXFreshKnownKey(const char *key);

/* 1 when a missing persistent value should be replaced by the Documents copy.
   A value already in the persistent domain is kept. Registered defaults do
   not count as persisted: the v2.4.2 log showed the key names through
   dictionaryRepresentation while both plists were missing. */
int IXFreshMarkerRestore(int persistent_present, int saved_present);

/* 1 when a known marker that has never been stored should be created.
   A saved or persisted value is not replaced by the placeholder. */
int IXFreshMarkerSeed(int persistent_present, int saved_present, int known_key);

/* 1 when an existing install has no fresh-install marker on disk.
   seen_launch is the Documents marker from a previous process.
   cookie_file is Instagram's cookie store, which survives the prefs wipe.
   marker_on_disk means a real marker was already in the Documents copy or
   a preference domain. A first launch (nothing seen, no cookies) returns 0
   so a brand-new install is not disguised. v2.4.5 logged
   ix_seen_launch=existing, cookie_file=yes, both plists absent. */
int IXSessionSeedFresh(int seen_launch, int cookie_file, int marker_on_disk);

/* Directory leaf the base sideload helper uses: the group identifier itself,
   under Documents. A slash, backslash, or ".." is rejected. NULL becomes
   group.com.burbn.instagram. */
int IXSessionContainerLeaf(const char *identifier, char *out, size_t outLen);

/* How many accounts to report to the panel.
   A non-zero harvest is the live count.
   Zero at launch is not a logout while the session cookie is still present
   or the restore window is still open: the saved count is kept.
   Zero after that window with no cookie is a real logout and returns 0. */
int IXSessionHoldCount(int harvested, int saved, int cookie_present, int within_restore_window);

/* What the heartbeat should put in ig_account_count.
   1: send the live harvest.
   2: send the saved list.
   0: send zero. The cookie is gone and the restore window has closed.
   -1: omit the fields. A zero harvest before restore, or a cookie with no
   saved list yet, must not replace the account the panel already stored. */
int IXSessionReportAccounts(int harvested, int saved, int cookie_present, int within_restore_window);

/* 1 when a SecItem access group must be replaced with the entitled group.
   The base sideload helper does this on add, copy, update, and delete.
   A missing group is replaced too. The entitled group itself is kept.
   A missing entitled group returns 0. */
int IXSessionRewriteGroup(const char *group, const char *entitled);

/* 1 when an NSUserDefaults suite must be stored in the app sandbox.
   The original IPA is entitled to group.com.burbn.instagram and
   group.com.facebook.family. A sideload profile is not, and those suites
   then do not survive a relaunch. Only a group.* name is redirected.
   A slash, backslash, or ".." is rejected. The app's own domain is not. */
int IXSessionPersistSuite(const char *suite);

/* Absolute plist path for a redirected group suite:
   <docs>/<suite>/Library/Preferences/<suite>.plist
   Returns 0 for a suite IXSessionPersistSuite rejects, or when the
   buffer is too small. docs is the app Documents directory. */
int IXSessionSuitePlist(const char *docs, const char *suite, char *out, size_t outLen);

/* 1 when a defaults key or a filesystem path is an auth/session store.
   Used to decide which deletions to record. Password values are never logged. */
int IXSessionSensitiveName(const char *name);

/* 1 when SecItemDelete may run.
   our_service is the diagnostics, backend, or VPN item and is always allowed.
   password_class is a generic password, an internet password, or a query
   with no class. Other classes are always allowed.
   marker_persisted is 1 when a fresh-install marker was already in the
   Documents file or a preference domain at process start. Registered
   defaults do not count.
   A previous install whose marker was missing refuses password deletes
   until didFinishLaunching returns. That is the v2.4.2 window: existing
   launch, both plists absent, accounts already 0 when launch returned,
   and the v2.4.1 delete that returned success. Once the marker is on
   disk, launch deletes stay allowed so a normal token refresh still
   works. After launch, a real logout is allowed. The first install is
   allowed. */
int IXSessionDeleteAllowed(int existing_install, int launch_finished, int marker_persisted, int our_service, int password_class);

/* 1 for instagramx.diag, instagramx.backend, and instagramx.vpn. */
int IXSessionOurService(const char *service);

/* 1 for "genp", "inet", an empty class, or NULL. Certificates and keys are 0. */
int IXSessionPasswordClass(const char *cls);

/* Directory leaf for a missing app-group container. v2.2.4 used one leaf for
   every group id. e0b8495 used the identifier, so the session directory moved
   when that string changed. The identifier is ignored. */
int IXSessionFallbackLeaf(const char *identifier, char *out, size_t outLen);

/* Suite used when METAAppGroup has no user defaults. v2.2.4 always used
   group.com.burbn.instagram. e0b8495 used the identifier. */
int IXSessionDefaultsSuite(const char *identifier, char *out, size_t outLen);

/* What to write into a nil METAAppGroup identifier. Returns 0 when `current`
   is already set: v2.2.4 left it alone, and replacing it made the next launch
   miss the session. A nil identifier gets the SecItem probe group, then the
   requested name. */
int IXSessionIdentifierFill(const char *current, const char *requested, const char *probe, char *out, size_t outLen);

#endif
