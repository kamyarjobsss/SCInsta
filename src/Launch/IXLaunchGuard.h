#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when two launches in a row began and neither reached the logged-in tab bar.
/// A crash after login, before the tab bar appears, counts. Extras (VPN restore,
/// fake location, the settings row, FLEX on launch) stay off until the user
/// turns one on. The tab bar marks the launch ready.
BOOL IXLaunchGuardIsSafeMode(void);
void IXLaunchGuardMarkReady(void);

NS_ASSUME_NONNULL_END
