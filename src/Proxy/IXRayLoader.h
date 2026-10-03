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

NS_ASSUME_NONNULL_END
