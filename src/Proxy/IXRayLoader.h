#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// dlopen of Frameworks/IXRayCore.dylib. The full IPA ships that file with no
/// load command, so dyld does not map it until the VPN is turned on.
BOOL IXRayCoreLoad(NSError * _Nullable * _Nullable error);
char * _Nullable IXRayStart(char * _Nullable configJSON);
void IXRayStop(void);
char * _Nullable IXRayVersion(void);
char * _Nullable IXRayCopyLog(void);
void IXRayTraffic(uint64_t * _Nullable uplink, uint64_t * _Nullable downlink);
/// A second Xray core for a latency probe. Does not close the live instance.
/// Returns 0 when the probe did not start.
int IXRayProbeOpen(char * _Nullable configJSON);
void IXRayProbeClose(int probeID);
/// Start a replacement core without closing the live one. NULL means it is listening.
char * _Nullable IXRayPrepare(char * _Nullable configJSON);
void IXRayPrepareAbort(void);
/// Point traffic stats at the prepared core and close the previous one.
char * _Nullable IXRayCommit(void);

NS_ASSUME_NONNULL_END
