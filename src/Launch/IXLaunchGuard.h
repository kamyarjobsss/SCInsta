#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when two launches in a row began and neither reached the ready mark.
/// Extras (VPN restore, fake location, the settings row, FLEX on launch) stay
/// off until the user turns one on. A launch that survives marks itself ready.
BOOL IXLaunchGuardIsSafeMode(void);
void IXLaunchGuardMarkReady(void);

NS_ASSUME_NONNULL_END
