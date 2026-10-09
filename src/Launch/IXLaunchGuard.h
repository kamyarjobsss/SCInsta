#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called from willFinishLaunching, before any VPN hook is installed.
/// A file left as "starting" means the previous launch died within 5 seconds.
/// This launch stays in safe mode, and that disable persists until Exit safe mode.
void IXLaunchGuardRecord(void);
/// YES until the user leaves safe mode. It does not clear itself.
BOOL IXLaunchGuardIsSafeMode(void);
/// The process has been alive for 5 seconds. Writes "alive".
/// A safe launch does not clear the persisted disable.
void IXLaunchGuardMarkReady(void);
BOOL IXLaunchGuardFeedShown(void);
/// Hold on the splash. Hooks stay off until Exit safe mode.
void IXLaunchGuardEngageBypass(void);
/// Leave safe mode now. Hooks may install. Dying again within 5s returns to safe mode.
void IXLaunchGuardExitSafeMode(void);

void IXLaunchGuardAppendLog(const char * _Nullable line);
NSString *IXLaunchGuardPersistedLog(void);

NS_ASSUME_NONNULL_END
