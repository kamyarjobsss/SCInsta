#import <Foundation/Foundation.h>
#import "IXVLESSProfile.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const IXProxyEnabledKey;
extern NSString *const IXProxyKillSwitchKey;
extern NSString *const IXProxyBlockUDPKey;
extern NSString *const IXProxyProfilesKey;
extern NSString *const IXProxySelectedKey;

typedef NS_ENUM(NSInteger, IXProxyStatus) {
    IXProxyStatusOff = 0,
    IXProxyStatusConnecting,
    IXProxyStatusConnected,
    IXProxyStatusFailed
};

@interface IXProxyManager : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) IXProxyStatus status;
@property (nonatomic, readonly, copy) NSString *statusText;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;
@property (nonatomic, readonly, copy) NSString *engineName;
@property (nonatomic, readonly) BOOL xrayLinked;

- (NSArray<IXVLESSProfile *> *)profiles;
- (nullable IXVLESSProfile *)selectedProfile;
- (void)addProfilesFromText:(NSString *)text error:(NSError * _Nullable * _Nullable)error;
- (void)removeProfileAtIndex:(NSUInteger)index;
- (void)selectProfile:(IXVLESSProfile *)profile;

- (void)setEnabled:(BOOL)enabled completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)setKillSwitch:(BOOL)on;
- (void)setBlockUDP:(BOOL)on;
- (BOOL)killSwitch;
- (BOOL)blockUDP;
/// Saved XHTTP mode for this server. Empty means the fallback has not picked one yet.
- (NSString *)xhttpModeForProfile:(IXVLESSProfile *)profile;
- (nullable NSString *)boundInterface;
- (void)setXHTTPMode:(nullable NSString *)mode forProfile:(IXVLESSProfile *)profile;
- (BOOL)isEnabled;

- (void)restoreOnLaunch;
/// Stops the live tunnel without clearing the saved on switch. Used by safe mode.
- (void)suppressForSafeMode;
/// Leaves safe mode and installs hooks when the saved VPN switch is on.
- (void)exitSafeMode;
- (void)testProfile:(IXVLESSProfile *)profile completion:(void (^)(NSInteger millis, NSError * _Nullable error))completion;
- (void)runTunnelTest:(void (^)(NSInteger millis, NSError * _Nullable error))completion;
- (void)checkExitIP:(void (^)(NSString * _Nullable summary, NSError * _Nullable error))completion;

- (uint64_t)bytesUp;
- (uint64_t)bytesDown;
- (double)speedUp;
- (double)speedDown;
- (NSInteger)lastPingMs;
- (NSString *)recentLog;

+ (NSString *)statusSubtitle;

@end

NS_ASSUME_NONNULL_END
