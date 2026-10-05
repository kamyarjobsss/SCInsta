#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called from willFinishLaunching, before any VPN hook is installed.
/// HOME is valid by then. A constructor is too early: the container and libc
/// are not ready, and a crash before the feed would not be recorded.
void IXLaunchGuardRecord(void);
/// YES when the previous launch did not reach the feed, or the user held a
/// finger on the splash. VPN hooks stay off until the user turns the VPN on.
BOOL IXLaunchGuardIsSafeMode(void);
/// The feed (or a login screen) is on screen, so this launch counts as healthy.
void IXLaunchGuardMarkReady(void);
BOOL IXLaunchGuardFeedShown(void);
/// Hold on the splash. This launch stops using the hooks. The saved VPN switch
/// is left as it is.
void IXLaunchGuardEngageBypass(void);

void IXLaunchGuardAppendLog(const char * _Nullable line);
NSString *IXLaunchGuardPersistedLog(void);

NS_ASSUME_NONNULL_END
