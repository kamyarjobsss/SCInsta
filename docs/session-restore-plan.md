# Session restore after close (diagnostic, not a release)

v2.4.10 still logs out because the sideload has no app-group entitlement. Instagram restores the user from group containers, group preference suites, a group keychain access group, and the group cookie jar. Those reads miss, `initialUserSession` stays empty, and `IGSessionManagerServiceInitOnStartup` calls `clearAllUsersWithLogoutEntryPoint:`. `instagram.activeaccount` surviving in the team keychain is not the session. `authheaders` is.

This branch only records which of those stores exist at startup. It does not change the restore path and it does not publish an IPA.

## What Instagram reads

FBSharedFramework and the main binary name these stores. The 2.4.8 device log showed the same ones empty or wiped:

1. `containerURLForSecurityApplicationGroupIdentifier:` and `METAAppGroup` `-containerURL` for `group.com.burbn.instagram`, `group.com.facebook.family`, and `group.com.burbn.family`. `-keychainAccessAppGroup` and `-userDefaults` hang off that object.
2. `NSUserDefaults` `initWithSuiteName:` / `_initWithSuiteName:container:` for those suite names. `logged_in_user_id` length 0 makes `getIsFirstUserEnterSession` true, which runs `onFirstAppInstall` (the fresh-install deletes are a consequence). `mc_freshinstall_time` lives in the same suites.
3. Keychain generic passwords. Services: `instagram.activeaccount`, `instagram.inactiveloggedinaccounts`, `com.instagram.users.authheaders.service`, `group.com.facebook.family.instagramtokenshare.service`, and `group.com.facebook.family.instagramtokenshare.key`. Access groups: the signing team's group (whatever SecItem assigns when the query omits one), plus the three group ids above. A missing entitlement returns -34018 for the group ids.
4. `NSHTTPCookieStorage` `sharedCookieStorageForGroupContainerIdentifier:` beside `sharedHTTPCookieStorage`. Names that matter: session cookie, `ds_user_id`, `csrftoken`, `mid`, `rur`. On disk: `Cookies.binarycookies` under `Library/Cookies` and under the group container.
5. Files in the group container: `Library/Preferences/<suite>.plist`, `Library/Cookies`, `mobileconfig`, `server_save_status.plist`, `save_expiration.plist`.
6. Keyed archive of the user: `persistAuthenticatedUsers`, `IGAuthenticatedUser`, `IGUserSession` (`NSKeyedArchiver`). `hasAuthHeader` false is the other clear-users condition.

`IGSessionManagerServiceInitOnStartup` is not a static initializer. One direct call sits in an ObjC method. `+load` can still reach it through `objc_msgSend`. v2.4.9 moved the tweak before FBSharedFramework and crashed. v2.4.10 kept the 2.4.8 load order, so SCInsta runs after that image is mapped.

## Why the 2.4.10 hooks still miss

- `containerURLForSecurityApplicationGroupIdentifier:` returns `%orig` whenever that URL is non-nil. An unentitled sideload gets nil or an ephemeral container. The Documents directory is used only for nil. A later file read of that URL never sees the stable copy.
- Suite and cookie redirects are installed only after FBSharedFramework is mapped, from the tweak constructor. That is early enough for `willFinishLaunching`, and too late for a `+load` read. The constructor does not walk classes and does not rebind SecItem.
- The keychain access-group rewrite runs in `IXSessionWatchArm`, which is the first call in our `willFinishLaunching` hook, still before `%orig`. A read that already happened in `+load` or in another image's constructor is unchanged. Items written into `group.com.*` stay unreadable (-34018) and are not copied into the team group first.
- The app-domain plist and `instagram.activeaccount` are the stores the 2.4.8 log showed surviving. They are not `initialUserSession`.

## Fix (next change, not this branch)

Do not add an app-group entitlement. Do not hardcode a team id. Do not move SCInsta or zxPluginsInject before FBSharedFramework. Do not seed `mc_freshinstall_time`. Do not block `SecItemDelete`.

1. `containerURLForSecurityApplicationGroupIdentifier:` always returns `Documents/<group id>` for a `group.*` identifier that passes `IXSessionPersistSuite`. Ignore a non-nil `%orig`. Create that directory. Copy an existing group-container tree into it once.
2. Open those `NSUserDefaults` suites on that directory (`initWithSuiteName:` and `_initWithSuiteName:container:`). Leave the app domain and `instagramx.*` alone.
3. On SecItem add, copy, update, and delete, set `kSecAttrAccessGroup` to the group SecItem assigned the probe item `instagramx.keychain-group-probe`. Arm that rebind from the constructor once FBSharedFramework is mapped, before `willFinishLaunching`, and do it without `objc_copyClassList`. If a device log shows the session read inside FB's initializer, add a tiny Foundation-only initializer ordered before FB. Do not move the rest of the tweak.
4. Point `sharedCookieStorageForGroupContainerIdentifier:` at `sharedHTTPCookieStorage` for those group ids.

The ctor-versus-`will_pre` lines from this branch decide whether step 3 must move earlier than `willFinishLaunching`. `will_pre` versus `will_post` shows whether `clearAllUsers` runs inside `willFinishLaunching`.

## What this branch logs

`source phase=<phase> kind=<kind> name=<name> present=<0|1> bytes=<n> detail=<detail>`

Phases: `ctor` (files only, before the suite hook and the cookie hook), `will_pre` (suite and cookie hooks already installed, keychain rebind not yet, before `%orig`), `will_post` (after `willFinish` `%orig`), `did_post` (after `didFinish` `%orig`). `ctor` versus `will_pre` is the window where a `+load` read can wipe a store the constructor hooks never saw. Keychain lines are status and count for the five services against `default`, `entitled`, `ig`, `family`, and `burbn`. The entitled group string is not printed. Cookie names are `session_cookie`, `ds_user`, `csrf`, `mid`, `rur`. Preference lines are `user_id` / `fresh_time` with `set`, `len0`, or `absent`. Paths are not printed; container lines use `missing`, `documents`, `system`, or `other`. Archive filenames with a run of six digits are skipped.
