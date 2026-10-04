#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Parsed vless:// link. `needsXray` is YES for transports the built-in engine
/// cannot speak (REALITY, Vision, gRPC, XHTTP, QUIC).
@interface IXVLESSProfile : NSObject <NSCopying>

@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, copy) NSString *host;
@property (nonatomic) uint16_t port;
@property (nonatomic, copy) NSString *network;   // tcp, ws, grpc, ...
@property (nonatomic, copy) NSString *security;  // none, tls, reality
@property (nonatomic, copy, nullable) NSString *flow;
@property (nonatomic, copy, nullable) NSString *sni;
@property (nonatomic, copy, nullable) NSString *fingerprint;
@property (nonatomic, copy, nullable) NSString *publicKey;
@property (nonatomic, copy, nullable) NSString *shortId;
@property (nonatomic, copy, nullable) NSString *spiderX;
@property (nonatomic, copy, nullable) NSString *path;
/// WebSocket early-data budget from `ed` or a path query `?ed=2048`.
@property (nonatomic) NSInteger earlyData;
@property (nonatomic, copy, nullable) NSString *wsHost;
@property (nonatomic, copy, nullable) NSString *serviceName;
@property (nonatomic, copy, nullable) NSString *alpn;
@property (nonatomic, copy, nullable) NSString *mode;
/// Raw JSON object from the link's `extra` query, used by xhttp.
@property (nonatomic, copy, nullable) NSString *xhttpExtra;
@property (nonatomic) BOOL allowInsecure;
@property (nonatomic) BOOL needsXray;
/// Resolved address for `dns.hosts` only. `vnext.address` stays the domain.
@property (nonatomic, copy, nullable) NSString *dialAddress;

+ (nullable instancetype)profileFromURI:(NSString *)uri error:(NSError * _Nullable * _Nullable)error;
+ (NSArray<IXVLESSProfile *> *)profilesFromPaste:(NSString *)text;

- (NSString *)displayName;
- (NSString *)endpointSummary;
/// Mode written into xhttpSettings. Empty and "auto" become stream-one; Xray's auto dials packet-up.
+ (NSString *)xrayXHTTPModeFrom:(NSString * _Nullable)mode;
- (NSDictionary *)xrayOutbound;
- (NSString *)xrayJSONWithSocksPort:(uint16_t)socksPort httpPort:(uint16_t)httpPort;

@end

NS_ASSUME_NONNULL_END
