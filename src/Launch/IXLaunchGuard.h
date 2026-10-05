#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called from willFinishLaunching, before any VPN hook is installed.
/// A file left as "starting" means the previous launch died early. This launch
/// stays in safe mode, and the file is cleared so the launch after that is normal.
void IXLaunchGuardRecord(void);
/// YES for this launch only. The next launch is not in safe mode.
BOOL IXLaunchGuardIsSafeMode(void);
/// The process is alive (an Instagram view appeared, or several seconds passed).
/// Clears the watchdog file. Does not turn hooks back on during a safe launch.
void IXLaunchGuardMarkReady(void);
BOOL IXLaunchGuardFeedShown(void);
/// Hold on the splash. Hooks stop for this launch. The next launch is normal.
void IXLaunchGuardEngageBypass(void);
/// Leave safe mode now and allow hooks to install on this launch.
void IXLaunchGuardExitSafeMode(void);

void IXLaunchGuardAppendLog(const char * _Nullable line);
NSString *IXLaunchGuardPersistedLog(void);

NS_ASSUME_NONNULL_END
