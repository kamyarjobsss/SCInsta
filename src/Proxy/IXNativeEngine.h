#import <Foundation/Foundation.h>
#import "IXVLESSProfile.h"

NS_ASSUME_NONNULL_BEGIN

/// Built-in VLESS client used when the Xray static library is not linked.
/// Speaks VLESS over TCP, TLS, and WebSocket+TLS. REALITY, Vision, gRPC and
/// XHTTP are refused with a clear error.
@interface IXNativeEngine : NSObject

@property (nonatomic, readonly) uint16_t socksPort;
@property (nonatomic, readonly) uint16_t httpPort;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (BOOL)startWithProfile:(IXVLESSProfile *)profile error:(NSError * _Nullable * _Nullable)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
