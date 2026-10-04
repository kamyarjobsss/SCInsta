#import "IXVLESSProfile.h"
#import <arpa/inet.h>

static NSString *IXPercentDecode(NSString *value) {
    if (value.length == 0) return @"";
    NSString *decoded = [value stringByRemovingPercentEncoding];
    return decoded ?: value;
}

static NSDictionary<NSString *, NSString *> *IXQuery(NSString *query) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (query.length == 0) return out;
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if (pair.length == 0) continue;
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            out[IXPercentDecode(pair)] = @"";
            continue;
        }
        NSString *key = IXPercentDecode([pair substringToIndex:eq.location]);
        NSString *val = IXPercentDecode([pair substringFromIndex:eq.location + 1]);
        if (key.length) out[key] = val ?: @"";
    }
    return out;
}

static NSError *IXURIError(NSString *message) {
    return [NSError errorWithDomain:@"InstagramX.VLESS" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Invalid vless link"}];
}

@implementation IXVLESSProfile

+ (nullable instancetype)profileFromURI:(NSString *)uri error:(NSError **)error {
    NSString *raw = [uri stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) {
        if (error) *error = IXURIError(@"Empty link.");
        return nil;
    }
    if (![raw.lowercaseString hasPrefix:@"vless://"]) {
        if (error) *error = IXURIError(@"Only vless:// links are supported.");
        return nil;
    }

    NSString *name = @"";
    NSString *body = [raw substringFromIndex:8];
    NSRange hash = [body rangeOfString:@"#" options:NSBackwardsSearch];
    if (hash.location != NSNotFound) {
        name = IXPercentDecode([body substringFromIndex:hash.location + 1]);
        body = [body substringToIndex:hash.location];
    }

    NSString *query = @"";
    NSRange q = [body rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        query = [body substringFromIndex:q.location + 1];
        body = [body substringToIndex:q.location];
    }

    NSRange at = [body rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location == NSNotFound || at.location == 0) {
        if (error) *error = IXURIError(@"That vless link is missing a UUID.");
        return nil;
    }
    NSString *uuid = [body substringToIndex:at.location];
    NSString *hostport = [body substringFromIndex:at.location + 1];
    if (![[[NSUUID alloc] initWithUUIDString:uuid] UUIDString]) {
        if (error) *error = IXURIError(@"The UUID in that vless link is not valid.");
        return nil;
    }

    NSString *host = nil;
    NSString *portString = nil;
    if ([hostport hasPrefix:@"["]) {
        NSRange end = [hostport rangeOfString:@"]"];
        if (end.location == NSNotFound) {
            if (error) *error = IXURIError(@"The IPv6 address in that link is malformed.");
            return nil;
        }
        host = [hostport substringWithRange:NSMakeRange(1, end.location - 1)];
        NSString *rest = [hostport substringFromIndex:end.location + 1];
        if ([rest hasPrefix:@":"]) portString = [rest substringFromIndex:1];
    } else {
        NSRange colon = [hostport rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location == NSNotFound) {
            if (error) *error = IXURIError(@"That vless link is missing a port.");
            return nil;
        }
        host = [hostport substringToIndex:colon.location];
        portString = [hostport substringFromIndex:colon.location + 1];
    }
    int port = portString.intValue;
    if (host.length == 0 || port < 1 || port > 65535) {
        if (error) *error = IXURIError(@"That vless link has a bad host or port.");
        return nil;
    }

    NSDictionary *params = IXQuery(query);
    NSString * (^param)(NSString *) = ^NSString *(NSString *key) {
        id value = params[key];
        return [value isKindOfClass:[NSString class]] ? value : @"";
    };
    NSString *encryption = param(@"encryption");
    if (encryption.length && ![encryption isEqualToString:@"none"]) {
        if (error) *error = IXURIError(@"VLESS encryption must be \"none\".");
        return nil;
    }

    IXVLESSProfile *profile = [IXVLESSProfile new];
    profile.uri = raw;
    profile.uuid = uuid.lowercaseString;
    profile.host = host;
    profile.port = (uint16_t)port;
    profile.network = param(@"type").length ? param(@"type").lowercaseString : @"tcp";
    if ([profile.network isEqualToString:@"raw"]) profile.network = @"tcp";
    profile.security = param(@"security").length ? param(@"security").lowercaseString : @"none";
    // WebSocket + VLESS rejects a non-empty flow. Keep every other field as written.
    profile.flow = [profile.network isEqualToString:@"ws"] ? @"" : param(@"flow");
    // host and sni are independent of the address. Never substitute the address.
    profile.sni = param(@"sni");
    profile.fingerprint = param(@"fp").length ? param(@"fp") : @"chrome";
    profile.publicKey = param(@"pbk");
    profile.shortId = param(@"sid");
    profile.spiderX = param(@"spx").length ? param(@"spx") : @"/";
    NSInteger earlyData = param(@"ed").integerValue;
    NSString *path = param(@"path").length ? param(@"path") : @"/";
    NSRange pathQuery = [path rangeOfString:@"?"];
    if (pathQuery.location != NSNotFound) {
        NSDictionary *inner = IXQuery([path substringFromIndex:pathQuery.location + 1]);
        if ([inner[@"ed"] integerValue] > 0) earlyData = [inner[@"ed"] integerValue];
        NSMutableArray *kept = [NSMutableArray array];
        for (NSString *key in inner) {
            if ([key isEqualToString:@"ed"] || ![inner[key] isKindOfClass:[NSString class]]) continue;
            [kept addObject:[NSString stringWithFormat:@"%@=%@", key, inner[key]]];
        }
        path = [path substringToIndex:pathQuery.location];
        if (kept.count) path = [path stringByAppendingFormat:@"?%@", [kept componentsJoinedByString:@"&"]];
    }
    if (path.length == 0) path = @"/";
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    profile.path = path;
    profile.earlyData = earlyData > 0 ? earlyData : 0;
    // Keep a trailing dot. v2Box sends this header verbatim.
    profile.wsHost = param(@"host");
    profile.serviceName = param(@"serviceName").length ? param(@"serviceName") : param(@"authority");
    profile.alpn = param(@"alpn");
    profile.mode = param(@"mode");
    profile.xhttpExtra = param(@"extra");
    BOOL (^flag)(NSString *) = ^BOOL(NSString *value) {
        return [value isEqualToString:@"1"] || [value isEqualToString:@"true"];
    };
    // `insecure` is an alias some clients emit beside `allowInsecure`.
    profile.allowInsecure = flag(param(@"allowInsecure")) || flag(param(@"insecure"));
    if (!name.length) name = [NSString stringWithFormat:@"%@:%d", host, port];
    profile.name = name;

    BOOL nativeOK = ([profile.network isEqualToString:@"tcp"] || [profile.network isEqualToString:@"ws"])
        && ([profile.security isEqualToString:@"none"] || [profile.security isEqualToString:@"tls"])
        && profile.flow.length == 0
        && profile.earlyData == 0;
    profile.needsXray = !nativeOK;
    return profile;
}

+ (NSArray<IXVLESSProfile *> *)profilesFromPaste:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @[];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if ([trimmed.lowercaseString containsString:@"vless://"]) {
        [lines addObjectsFromArray:[trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
    } else {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:trimmed options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *expanded = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
        if ([expanded.lowercaseString containsString:@"vless://"]) {
            [lines addObjectsFromArray:[expanded componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
        } else {
            [lines addObject:trimmed];
        }
    }

    NSMutableArray *profiles = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *line in lines) {
        NSString *item = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (item.length == 0 || [item hasPrefix:@"#"]) continue;
        NSRange scheme = [item.lowercaseString rangeOfString:@"vless://"];
        if (scheme.location == NSNotFound) continue;
        if (scheme.location > 0) item = [item substringFromIndex:scheme.location];
        IXVLESSProfile *profile = [IXVLESSProfile profileFromURI:item error:nil];
        if (!profile || [seen containsObject:profile.uri]) continue;
        [seen addObject:profile.uri];
        [profiles addObject:profile];
    }
    return profiles;
}

- (NSString *)displayName {
    return self.name.length ? self.name : [self endpointSummary];
}

- (NSString *)endpointSummary {
    return [NSString stringWithFormat:@"%@:%u · %@/%@", self.host, self.port, self.security ?: @"none", self.network ?: @"tcp"];
}

- (id)copyWithZone:(NSZone *)zone {
    return [IXVLESSProfile profileFromURI:self.uri error:nil] ?: self;
}

- (NSDictionary *)xrayOutbound {
    NSMutableDictionary *user = [@{
        @"id": self.uuid ?: @"",
        @"encryption": @"none"
    } mutableCopy];
    if (self.flow.length && ![self.network isEqualToString:@"ws"]) user[@"flow"] = self.flow;

    NSMutableDictionary *stream = [@{@"network": self.network ?: @"tcp"} mutableCopy];
    NSString *security = self.security.length ? self.security : @"none";
    stream[@"security"] = security;

    if ([self.network isEqualToString:@"ws"]) {
        NSString *wsPath = self.path.length ? self.path : @"/";
        if (self.earlyData > 0 && [wsPath rangeOfString:@"ed="].location == NSNotFound) {
            // Xray 26.3.27 reads early data only from the path query.
            wsPath = [NSString stringWithFormat:@"%@%@ed=%ld", wsPath, [wsPath containsString:@"?"] ? @"&" : @"?", (long)self.earlyData];
        }
        NSMutableDictionary *ws = [@{
            @"path": wsPath,
            @"heartbeatPeriod": @15
        } mutableCopy];
        if (self.wsHost.length) ws[@"host"] = self.wsHost;
        stream[@"wsSettings"] = ws;
    } else if ([self.network isEqualToString:@"grpc"]) {
        stream[@"grpcSettings"] = @{@"serviceName": self.serviceName ?: @""};
    } else if ([self.network isEqualToString:@"xhttp"] || [self.network isEqualToString:@"splithttp"]) {
        stream[@"network"] = @"xhttp";
        NSMutableDictionary *xhttp = [@{
            @"path": self.path.length ? self.path : @"/"
        } mutableCopy];
        if (self.wsHost.length) xhttp[@"host"] = self.wsHost;
        // packet-up is Xray's default and Fastly answers it with PROTOCOL_ERROR.
        // Keep an explicit link mode. Otherwise use stream-one, which CDNs accept.
        xhttp[@"mode"] = self.mode.length ? self.mode : @"stream-one";
        if (self.xhttpExtra.length) {
            NSData *extraData = [self.xhttpExtra dataUsingEncoding:NSUTF8StringEncoding];
            id extra = extraData ? [NSJSONSerialization JSONObjectWithData:extraData options:0 error:nil] : nil;
            if ([extra isKindOfClass:[NSDictionary class]]) xhttp[@"extra"] = extra;
        }
        stream[@"xhttpSettings"] = xhttp;
    } else if ([self.network isEqualToString:@"h2"] || [self.network isEqualToString:@"http"]) {
        stream[@"network"] = @"h2";
        stream[@"httpSettings"] = @{
            @"path": self.path.length ? self.path : @"/",
            @"host": self.wsHost.length ? @[self.wsHost] : @[]
        };
    }

    if ([security isEqualToString:@"tls"]) {
        NSMutableDictionary *tls = [@{
            @"allowInsecure": @(self.allowInsecure)
        } mutableCopy];
        if (self.sni.length) tls[@"serverName"] = self.sni;
        if (self.fingerprint.length) tls[@"fingerprint"] = self.fingerprint;
        if (self.alpn.length) {
            tls[@"alpn"] = [self.alpn componentsSeparatedByString:@","];
        }
        stream[@"tlsSettings"] = tls;
    } else if ([security isEqualToString:@"reality"]) {
        NSMutableDictionary *reality = [@{
            @"serverName": self.sni.length ? self.sni : @"",
            @"fingerprint": self.fingerprint.length ? self.fingerprint : @"chrome",
            @"publicKey": self.publicKey ?: @"",
            @"shortId": self.shortId ?: @"",
            @"spiderX": self.spiderX.length ? self.spiderX : @"/"
        } mutableCopy];
        if (!self.sni.length) [reality removeObjectForKey:@"serverName"];
        stream[@"realitySettings"] = reality;
    }

    stream[@"sockopt"] = @{
        @"domainStrategy": @"UseIPv4",
        @"tcpKeepAliveIdle": @30,
        @"tcpKeepAliveInterval": @15
    };

    return @{
        @"tag": @"proxy",
        @"protocol": @"vless",
        @"settings": @{
            @"vnext": @[@{
                @"address": self.host ?: @"",
                @"port": @(self.port),
                @"users": @[user]
            }]
        },
        @"streamSettings": stream,
        @"mux": @{
            @"enabled": @NO,
            @"concurrency": @(-1)
        }
    };
}

- (NSString *)xrayJSONWithSocksPort:(uint16_t)socksPort httpPort:(uint16_t)httpPort {
    NSString *server = self.host ?: @"";
    NSMutableArray *dnsServers = [NSMutableArray array];
    if (server.length && ![self ix_hostIsIP:server]) {
        // https+local sends this lookup from the device, not through the proxy.
        // Otherwise Xray asks the proxy to resolve its own address and the lookup dies.
        for (NSString *address in @[
            @"https+local://1.1.1.1/dns-query",
            @"https+local://1.0.0.1/dns-query",
            @"https+local://8.8.8.8/dns-query",
            @"https+local://8.8.4.4/dns-query"
        ]) {
            [dnsServers addObject:@{
                @"address": address,
                @"domains": @[[@"full:" stringByAppendingString:server]],
                @"skipFallback": @YES
            }];
        }
    }
    [dnsServers addObject:@"https://1.1.1.1/dns-query"];
    [dnsServers addObject:@"https://dns.google/dns-query"];
    NSMutableDictionary *dns = [@{
        @"queryStrategy": @"UseIPv4",
        @"servers": dnsServers
    } mutableCopy];
    if (server.length && self.dialAddress.length && ![self.dialAddress isEqualToString:server]) {
        dns[@"hosts"] = @{server: self.dialAddress};
    }
    NSDictionary *sniff = @{
        @"enabled": @YES,
        @"destOverride": @[@"http", @"tls", @"quic"],
        @"metadataOnly": @NO,
        @"routeOnly": @YES
    };
    NSDictionary *httpSniff = @{
        @"enabled": @YES,
        @"destOverride": @[@"http", @"tls"],
        @"metadataOnly": @NO,
        @"routeOnly": @YES
    };
    NSDictionary *config = @{
        @"log": @{@"loglevel": @"warning"},
        @"dns": dns,
        @"inbounds": @[
            @{
                @"listen": @"127.0.0.1",
                @"port": @(socksPort),
                @"protocol": @"socks",
                @"settings": @{@"auth": @"noauth", @"udp": @YES},
                @"tag": @"socks-in",
                @"sniffing": sniff
            },
            @{
                @"listen": @"::1",
                @"port": @(socksPort),
                @"protocol": @"socks",
                @"settings": @{@"auth": @"noauth", @"udp": @YES},
                @"tag": @"socks-in6",
                @"sniffing": sniff
            },
            @{
                @"tag": @"http-in",
                @"listen": @"127.0.0.1",
                @"port": @(httpPort),
                @"protocol": @"http",
                @"settings": @{},
                @"sniffing": httpSniff
            },
            @{
                @"tag": @"http-in6",
                @"listen": @"::1",
                @"port": @(httpPort),
                @"protocol": @"http",
                @"settings": @{},
                @"sniffing": httpSniff
            }
        ],
        @"outbounds": @[
            [self xrayOutbound],
            @{
                @"tag": @"direct",
                @"protocol": @"freedom",
                @"settings": @{@"domainStrategy": @"UseIP"}
            },
            @{
                @"tag": @"dns-out",
                @"protocol": @"dns"
            }
        ],
        @"stats": @{},
        @"policy": @{
            @"system": @{
                @"statsInboundUplink": @YES,
                @"statsInboundDownlink": @YES
            }
        },
        @"routing": @{
            @"domainStrategy": @"AsIs",
            @"rules": @[
                @{
                    @"type": @"field",
                    @"ip": @[@"1.1.1.1", @"1.0.0.1", @"8.8.8.8", @"8.8.4.4"],
                    @"port": @"443",
                    @"outboundTag": @"direct"
                }
            ]
        }
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

- (BOOL)ix_hostIsIP:(NSString *)host {
    if (host.length == 0) return NO;
    struct in_addr v4;
    struct in6_addr v6;
    return inet_pton(AF_INET, host.UTF8String, &v4) == 1 || inet_pton(AF_INET6, host.UTF8String, &v6) == 1;
}

@end
