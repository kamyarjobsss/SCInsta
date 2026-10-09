#import "IXVLESSProfile.h"
#import <arpa/inet.h>

static NSString *IXPadBase64(NSString *value) {
    NSString *text = [[value stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger remainder = text.length % 4;
    if (remainder == 0) return text;
    return [text stringByPaddingToLength:text.length + (4 - remainder) withString:@"=" startingAtIndex:0];
}

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

+ (nullable instancetype)profileFromVLESSBody:(NSString *)raw error:(NSError **)error {

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
    profile.protocolName = @"vless";
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

- (void)ix_applyTransport:(NSDictionary<NSString *, NSString *> *)params defaultSecurity:(NSString *)defaultSecurity {
    NSString * (^param)(NSString *) = ^NSString *(NSString *key) {
        id value = params[key];
        return [value isKindOfClass:[NSString class]] ? value : @"";
    };
    NSString *network = param(@"type");
    if (network.length == 0) network = param(@"net");
    if (network.length == 0) network = @"tcp";
    network = network.lowercaseString;
    if ([network isEqualToString:@"raw"]) network = @"tcp";
    self.network = network;
    NSString *security = param(@"security");
    if (security.length == 0) security = param(@"tls");
    if (security.length == 0) security = defaultSecurity ?: @"none";
    if ([security isEqualToString:@"1"] || [security isEqualToString:@"true"]) security = @"tls";
    self.security = security.lowercaseString;
    self.flow = [self.network isEqualToString:@"ws"] ? @"" : param(@"flow");
    self.sni = param(@"sni");
    self.fingerprint = param(@"fp").length ? param(@"fp") : @"chrome";
    self.publicKey = param(@"pbk");
    self.shortId = param(@"sid");
    self.spiderX = param(@"spx").length ? param(@"spx") : @"/";
    NSInteger earlyData = param(@"ed").integerValue;
    NSString *path = param(@"path").length ? param(@"path") : @"/";
    NSRange pathQuery = [path rangeOfString:@"?"];
    if (pathQuery.location != NSNotFound) {
        NSDictionary *inner = IXQuery([path substringFromIndex:pathQuery.location + 1]);
        if ([inner[@"ed"] integerValue] > 0) earlyData = [inner[@"ed"] integerValue];
        path = [path substringToIndex:pathQuery.location];
    }
    if (path.length == 0) path = @"/";
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    self.path = path;
    self.earlyData = earlyData > 0 ? earlyData : 0;
    self.wsHost = param(@"host");
    self.serviceName = param(@"serviceName").length ? param(@"serviceName") : param(@"authority");
    self.alpn = param(@"alpn");
    self.mode = param(@"mode");
    self.xhttpExtra = param(@"extra");
    BOOL (^flag)(NSString *) = ^BOOL(NSString *value) {
        return [value isEqualToString:@"1"] || [value.lowercaseString isEqualToString:@"true"];
    };
    self.allowInsecure = flag(param(@"allowInsecure")) || flag(param(@"insecure"));
    self.needsXray = YES;
}

+ (BOOL)ix_splitHostPort:(NSString *)hostport host:(NSString * __autoreleasing *)hostOut port:(int *)portOut error:(NSError **)error {
    NSString *host = nil;
    NSString *portString = nil;
    if ([hostport hasPrefix:@"["]) {
        NSRange end = [hostport rangeOfString:@"]"];
        if (end.location == NSNotFound) {
            if (error) *error = IXURIError(@"The IPv6 address in that link is malformed.");
            return NO;
        }
        host = [hostport substringWithRange:NSMakeRange(1, end.location - 1)];
        NSString *rest = [hostport substringFromIndex:end.location + 1];
        if ([rest hasPrefix:@":"]) portString = [rest substringFromIndex:1];
    } else {
        NSRange colon = [hostport rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location == NSNotFound) {
            if (error) *error = IXURIError(@"That link is missing a port.");
            return NO;
        }
        host = [hostport substringToIndex:colon.location];
        portString = [hostport substringFromIndex:colon.location + 1];
    }
    int port = portString.intValue;
    if (host.length == 0 || port < 1 || port > 65535) {
        if (error) *error = IXURIError(@"That link has a bad host or port.");
        return NO;
    }
    if (hostOut) *hostOut = host;
    if (portOut) *portOut = port;
    return YES;
}

+ (nullable instancetype)profileFromTrojan:(NSString *)raw error:(NSError **)error {
    NSString *name = @"";
    NSString *body = [raw substringFromIndex:9];
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
        if (error) *error = IXURIError(@"That trojan link is missing a password.");
        return nil;
    }
    NSString *host = nil;
    int port = 0;
    if (![self ix_splitHostPort:[body substringFromIndex:at.location + 1] host:&host port:&port error:error]) return nil;
    IXVLESSProfile *profile = [IXVLESSProfile new];
    profile.uri = raw;
    profile.protocolName = @"trojan";
    profile.password = IXPercentDecode([body substringToIndex:at.location]);
    profile.host = host;
    profile.port = (uint16_t)port;
    [profile ix_applyTransport:IXQuery(query) defaultSecurity:@"tls"];
    if (!name.length) name = [NSString stringWithFormat:@"%@:%d", host, port];
    profile.name = name;
    return profile;
}

+ (nullable instancetype)profileFromVMess:(NSString *)raw error:(NSError **)error {
    NSString *body = [raw substringFromIndex:8];
    NSRange hash = [body rangeOfString:@"#" options:NSBackwardsSearch];
    if (hash.location != NSNotFound) body = [body substringToIndex:hash.location];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:IXPadBase64(body) options:NSDataBase64DecodingIgnoreUnknownCharacters];
    id json = decoded ? [NSJSONSerialization JSONObjectWithData:decoded options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) *error = IXURIError(@"That vmess link is not valid base64 JSON.");
        return nil;
    }
    NSDictionary *object = json;
    id (^field)(NSString *) = ^id(NSString *key) {
        id value = object[key];
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) return value;
        return @"";
    };
    NSString *host = [field(@"add") description];
    int port = [[field(@"port") description] intValue];
    NSString *uuid = [field(@"id") description];
    if (host.length == 0 || port < 1 || port > 65535 || ![[[NSUUID alloc] initWithUUIDString:uuid] UUIDString]) {
        if (error) *error = IXURIError(@"That vmess link is missing a host, port, or UUID.");
        return nil;
    }
    IXVLESSProfile *profile = [IXVLESSProfile new];
    profile.uri = raw;
    profile.protocolName = @"vmess";
    profile.uuid = uuid.lowercaseString;
    profile.host = host;
    profile.port = (uint16_t)port;
    profile.alterId = [[field(@"aid") description] integerValue];
    profile.method = [field(@"scy") description].length ? [[field(@"scy") description] lowercaseString] : @"auto";
    NSString *name = [field(@"ps") description];
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSString *net = [field(@"net") description];
    if (net.length) params[@"type"] = net.lowercaseString;
    NSString *tls = [field(@"tls") description];
    if (tls.length) params[@"security"] = tls.lowercaseString;
    if ([field(@"host") description].length) params[@"host"] = [field(@"host") description];
    if ([field(@"path") description].length) params[@"path"] = [field(@"path") description];
    if ([field(@"sni") description].length) params[@"sni"] = [field(@"sni") description];
    if ([field(@"alpn") description].length) params[@"alpn"] = [field(@"alpn") description];
    if ([field(@"fp") description].length) params[@"fp"] = [field(@"fp") description];
    if ([field(@"serviceName") description].length) params[@"serviceName"] = [field(@"serviceName") description];
    [profile ix_applyTransport:params defaultSecurity:@"none"];
    profile.name = name.length ? name : [NSString stringWithFormat:@"%@:%d", host, port];
    return profile;
}

+ (nullable instancetype)profileFromSS:(NSString *)raw error:(NSError **)error {
    NSString *name = @"";
    NSString *body = [raw substringFromIndex:5];
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
    NSString *method = nil;
    NSString *password = nil;
    NSString *host = nil;
    int port = 0;
    NSRange at = [body rangeOfString:@"@"];
    if (at.location != NSNotFound) {
        NSString *user = IXPercentDecode([body substringToIndex:at.location]);
        NSData *userData = [[NSData alloc] initWithBase64EncodedString:IXPadBase64(user) options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *userText = userData ? [[NSString alloc] initWithData:userData encoding:NSUTF8StringEncoding] : nil;
        if (userText.length == 0) userText = user;
        NSRange colon = [userText rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            if (error) *error = IXURIError(@"That shadowsocks link is missing a method.");
            return nil;
        }
        method = [userText substringToIndex:colon.location];
        password = [userText substringFromIndex:colon.location + 1];
        if (![self ix_splitHostPort:[body substringFromIndex:at.location + 1] host:&host port:&port error:error]) return nil;
    } else {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:IXPadBase64(body) options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *text = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
        NSRange decodedAt = [text rangeOfString:@"@" options:NSBackwardsSearch];
        NSRange colon = [text rangeOfString:@":"];
        if (decodedAt.location == NSNotFound || colon.location == NSNotFound || colon.location > decodedAt.location) {
            if (error) *error = IXURIError(@"That shadowsocks link could not be decoded.");
            return nil;
        }
        method = [text substringToIndex:colon.location];
        password = [text substringWithRange:NSMakeRange(colon.location + 1, decodedAt.location - colon.location - 1)];
        if (![self ix_splitHostPort:[text substringFromIndex:decodedAt.location + 1] host:&host port:&port error:error]) return nil;
    }
    if (method.length == 0 || password.length == 0) {
        if (error) *error = IXURIError(@"That shadowsocks link is missing a method or password.");
        return nil;
    }
    IXVLESSProfile *profile = [IXVLESSProfile new];
    profile.uri = raw;
    profile.protocolName = @"shadowsocks";
    profile.method = method.lowercaseString;
    profile.password = password;
    profile.host = host;
    profile.port = (uint16_t)port;
    [profile ix_applyTransport:IXQuery(query) defaultSecurity:@"none"];
    profile.name = name.length ? name : [NSString stringWithFormat:@"%@:%d", host, port];
    return profile;
}

+ (nullable instancetype)profileFromURI:(NSString *)uri error:(NSError **)error {
    NSString *raw = [uri stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) {
        if (error) *error = IXURIError(@"Empty link.");
        return nil;
    }
    NSString *lower = raw.lowercaseString;
    if ([lower hasPrefix:@"vless://"]) return [self profileFromVLESSBody:raw error:error];
    if ([lower hasPrefix:@"trojan://"]) return [self profileFromTrojan:raw error:error];
    if ([lower hasPrefix:@"vmess://"]) return [self profileFromVMess:raw error:error];
    if ([lower hasPrefix:@"ss://"]) return [self profileFromSS:raw error:error];
    if (error) *error = IXURIError(@"Paste a vless://, trojan://, vmess://, or ss:// link.");
    return nil;
}

+ (NSArray<IXVLESSProfile *> *)profilesFromPaste:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @[];

    NSArray<NSString *> *schemes = @[@"vless://", @"trojan://", @"vmess://", @"ss://"];
    BOOL (^containsScheme)(NSString *) = ^BOOL(NSString *value) {
        NSString *lower = value.lowercaseString ?: @"";
        for (NSString *scheme in schemes) {
            if ([lower containsString:scheme]) return YES;
        }
        return NO;
    };
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (containsScheme(trimmed)) {
        [lines addObjectsFromArray:[trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
    } else {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:trimmed options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *expanded = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
        if (containsScheme(expanded)) {
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
        NSRange scheme = NSMakeRange(NSNotFound, 0);
        NSString *lower = item.lowercaseString;
        for (NSString *name in schemes) {
            NSRange found = [lower rangeOfString:name];
            if (found.location != NSNotFound && (scheme.location == NSNotFound || found.location < scheme.location)) scheme = found;
        }
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
    return [NSString stringWithFormat:@"%@ %@:%u · %@/%@", self.protocolName ?: @"vless", self.host, self.port, self.security ?: @"none", self.network ?: @"tcp"];
}

+ (NSString *)xrayXHTTPModeFrom:(NSString *)mode {
    NSString *lower = mode.lowercaseString;
    if ([lower isEqualToString:@"packet-up"] || [lower isEqualToString:@"stream-up"] || [lower isEqualToString:@"stream-one"] || [lower isEqualToString:@"auto"]) {
        return lower;
    }
    // v2Box and Xray leave a missing mode as auto. Xray then picks packet-up on TLS.
    return @"auto";
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
        xhttp[@"mode"] = [IXVLESSProfile xrayXHTTPModeFrom:self.mode];
        NSMutableDictionary *extra = [NSMutableDictionary dictionary];
        if (self.xhttpExtra.length) {
            NSData *extraData = [self.xhttpExtra dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = extraData ? [NSJSONSerialization JSONObjectWithData:extraData options:0 error:nil] : nil;
            if ([parsed isKindOfClass:[NSDictionary class]]) [extra addEntriesFromDictionary:parsed];
        }
        // Same client defaults v2rayNG documents and v2Box's XHTTP optimize uses.
        // noGRPCHeader keeps Fastly from treating stream-up/stream-one as gRPC.
        if (!extra[@"xPaddingBytes"]) extra[@"xPaddingBytes"] = @"100-1000";
        if (extra[@"noGRPCHeader"] == nil) extra[@"noGRPCHeader"] = @YES;
        if (extra[@"scMaxEachPostBytes"] == nil) extra[@"scMaxEachPostBytes"] = @1000000;
        xhttp[@"extra"] = extra;
        stream[@"xhttpSettings"] = xhttp;
    } else if ([self.network isEqualToString:@"httpupgrade"]) {
        NSMutableDictionary *upgrade = [@{@"path": self.path.length ? self.path : @"/"} mutableCopy];
        if (self.wsHost.length) upgrade[@"host"] = self.wsHost;
        stream[@"httpupgradeSettings"] = upgrade;
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

    NSMutableDictionary *sockopt = [@{
        @"domainStrategy": @"UseIPv4",
        @"tcpKeepAliveIdle": @30,
        @"tcpKeepAliveInterval": @15
    } mutableCopy];
    // Darwin applies this with IP_BOUND_IF / IPV6_BOUND_IF, so the dial does not
    // use a utun address when the phone's VPN is on.
    if (self.outboundInterface.length) sockopt[@"interface"] = self.outboundInterface;
    stream[@"sockopt"] = sockopt;

    NSString *protocol = self.protocolName.length ? self.protocolName : @"vless";
    NSDictionary *settings = nil;
    if ([protocol isEqualToString:@"trojan"]) {
        settings = @{@"servers": @[@{
            @"address": self.host ?: @"",
            @"port": @(self.port),
            @"password": self.password ?: @""
        }]};
    } else if ([protocol isEqualToString:@"shadowsocks"]) {
        settings = @{@"servers": @[@{
            @"address": self.host ?: @"",
            @"port": @(self.port),
            @"method": self.method ?: @"aes-256-gcm",
            @"password": self.password ?: @""
        }]};
    } else if ([protocol isEqualToString:@"vmess"]) {
        NSDictionary *vmessUser = @{
            @"id": self.uuid ?: @"",
            @"alterId": @(self.alterId),
            @"security": self.method.length ? self.method : @"auto"
        };
        settings = @{@"vnext": @[@{
            @"address": self.host ?: @"",
            @"port": @(self.port),
            @"users": @[vmessUser]
        }]};
    } else {
        protocol = @"vless";
        settings = @{@"vnext": @[@{
            @"address": self.host ?: @"",
            @"port": @(self.port),
            @"users": @[user]
        }]};
    }

    return @{
        @"tag": @"proxy",
        @"protocol": protocol,
        @"settings": settings,
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
    NSDictionary *inboundStream = @{
        @"sockopt": @{
            @"tcpKeepAliveIdle": @30,
            @"tcpKeepAliveInterval": @15,
            @"tcpNoDelay": @YES
        }
    };
    NSDictionary *config = @{
        @"log": @{@"loglevel": @"warning"},
        @"dns": dns,
        @"inbounds": @[
            @{
                @"listen": @"127.0.0.1",
                @"port": @(socksPort),
                @"protocol": @"socks",
                @"settings": @{@"auth": @"noauth", @"udp": @NO, @"userLevel": @0},
                @"streamSettings": inboundStream,
                @"tag": @"socks-in",
                @"sniffing": sniff
            },
            @{
                @"listen": @"::1",
                @"port": @(socksPort),
                @"protocol": @"socks",
                @"settings": @{@"auth": @"noauth", @"udp": @NO, @"userLevel": @0},
                @"streamSettings": inboundStream,
                @"tag": @"socks-in6",
                @"sniffing": sniff
            },
            @{
                @"tag": @"http-in",
                @"listen": @"127.0.0.1",
                @"port": @(httpPort),
                @"protocol": @"http",
                @"settings": @{@"userLevel": @0},
                @"streamSettings": inboundStream,
                @"sniffing": httpSniff
            },
            @{
                @"tag": @"http-in6",
                @"listen": @"::1",
                @"port": @(httpPort),
                @"protocol": @"http",
                @"settings": @{@"userLevel": @0},
                @"streamSettings": inboundStream,
                @"sniffing": httpSniff
            }
        ],
        @"outbounds": @[
            [self xrayOutbound],
            @{
                @"tag": @"direct",
                @"protocol": @"freedom",
                @"settings": @{@"domainStrategy": @"UseIPv4"},
                @"streamSettings": @{
                    @"sockopt": self.outboundInterface.length ? @{@"interface": self.outboundInterface} : @{}
                }
            },
            @{
                @"tag": @"dns-out",
                @"protocol": @"dns"
            }
        ],
        @"stats": @{},
        @"policy": @{
            @"levels": @{
                @"0": @{
                    @"handshake": @8,
                    @"connIdle": @300,
                    @"uplinkOnly": @2,
                    @"downlinkOnly": @5,
                    @"bufferSize": @512
                }
            },
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
