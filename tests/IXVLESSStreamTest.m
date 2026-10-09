#import <Foundation/Foundation.h>
#import "IXVLESSProfile.h"

static int gFailures;

static void IXExpect(BOOL ok, NSString *message) {
    if (ok) return;
    gFailures++;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
}

int main(void) {
    @autoreleasepool {
        NSString *link =
            @"vless://00000000-0000-0000-0000-000000000000@mainweb.iwur274.f.garqino.ir:443"
            @"?fp=firefox&security=tls&type=ws"
            @"&host=Kingkingprofosor123.global.ssl.fastly.net."
            @"&alpn=http%2F1.1&allowInsecure=0&encryption=none&insecure=0"
            @"&path=%2F&sni=ssl.fastly.com#test";
        NSError *error = nil;
        IXVLESSProfile *profile = [IXVLESSProfile profileFromURI:link error:&error];
        IXExpect(profile != nil, error.localizedDescription ?: @"profile did not parse");
        if (!profile) return 1;

        IXExpect([profile.host isEqualToString:@"mainweb.iwur274.f.garqino.ir"], @"address host");
        IXExpect(profile.port == 443, @"port");
        IXExpect([profile.wsHost isEqualToString:@"Kingkingprofosor123.global.ssl.fastly.net."], @"ws host keeps the trailing dot");
        IXExpect([profile.sni isEqualToString:@"ssl.fastly.com"], @"sni");
        IXExpect([profile.path isEqualToString:@"/"], @"path is decoded once");
        IXExpect([profile.fingerprint isEqualToString:@"firefox"], @"fingerprint");
        IXExpect([profile.alpn isEqualToString:@"http/1.1"], @"alpn");
        IXExpect(profile.allowInsecure == NO, @"allowInsecure=0 and insecure=0 stay off");
        IXExpect(profile.flow.length == 0, @"ws flow is empty");
        IXExpect(profile.earlyData == 0, @"this link has no ed");

        NSDictionary *outbound = [profile xrayOutbound];
        NSDictionary *vnext = [outbound[@"settings"][@"vnext"] firstObject];
        IXExpect([vnext[@"address"] isEqualToString:@"mainweb.iwur274.f.garqino.ir"], @"vnext dials the address domain");
        IXExpect([vnext[@"port"] isEqual:@443], @"vnext port");
        NSDictionary *user = [vnext[@"users"] firstObject];
        IXExpect([user[@"encryption"] isEqualToString:@"none"], @"encryption none");
        IXExpect(user[@"flow"] == nil, @"flow omitted");

        NSDictionary *stream = outbound[@"streamSettings"];
        NSDictionary *ws = stream[@"wsSettings"];
        IXExpect([ws[@"host"] isEqualToString:@"Kingkingprofosor123.global.ssl.fastly.net."], @"wsSettings.host");
        IXExpect([ws[@"path"] isEqualToString:@"/"], @"wsSettings.path");
        IXExpect(ws[@"headers"] == nil, @"headers.Host is not set");
        IXExpect([ws[@"host"] rangeOfString:@"mainweb.iwur274.f.garqino.ir"].location == NSNotFound, @"ws host is not the address");

        NSDictionary *tls = stream[@"tlsSettings"];
        IXExpect([tls[@"serverName"] isEqualToString:@"ssl.fastly.com"], @"tls serverName");
        IXExpect([tls[@"fingerprint"] isEqualToString:@"firefox"], @"tls fingerprint");
        IXExpect([tls[@"alpn"] isEqual:@[@"http/1.1"]], @"tls alpn");
        IXExpect([tls[@"allowInsecure"] isEqual:@NO], @"tls allowInsecure");
        IXExpect(![tls[@"serverName"] isEqualToString:profile.host], @"sni is not the address");

        NSString *plain =
            @"vless://00000000-0000-0000-0000-000000000000@example.com:443"
            @"?security=tls&type=ws&host=cdn.example&sni=sni.example&path=%2Fws";
        IXVLESSProfile *noAlpn = [IXVLESSProfile profileFromURI:plain error:nil];
        NSDictionary *plainTLS = [noAlpn xrayOutbound][@"streamSettings"][@"tlsSettings"];
        IXExpect(plainTLS[@"alpn"] == nil, @"absent alpn is not forced to http/1.1");
        IXExpect([plainTLS[@"serverName"] isEqualToString:@"sni.example"], @"sni stays independent");
        IXExpect([[noAlpn xrayOutbound][@"streamSettings"][@"wsSettings"][@"host"] isEqualToString:@"cdn.example"], @"ws host stays independent");

        NSString *insecure =
            @"vless://00000000-0000-0000-0000-000000000000@example.com:443"
            @"?security=tls&type=tcp&insecure=1";
        IXVLESSProfile *open = [IXVLESSProfile profileFromURI:insecure error:nil];
        IXExpect(open.allowInsecure == YES, @"insecure=1 sets allowInsecure");
        IXExpect([[open xrayOutbound][@"streamSettings"][@"tlsSettings"][@"allowInsecure"] isEqual:@YES], @"insecure alias reaches tlsSettings");

        NSString *insecureTrue =
            @"vless://00000000-0000-0000-0000-000000000000@example.com:443"
            @"?security=tls&type=tcp&insecure=true";
        IXVLESSProfile *openTrue = [IXVLESSProfile profileFromURI:insecureTrue error:nil];
        IXExpect(openTrue.allowInsecure == YES, @"insecure=true sets allowInsecure");

        profile.dialAddress = @"199.232.11.1";
        NSData *configData = [[profile xrayJSONWithSocksPort:1080 httpPort:1081] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *config = [NSJSONSerialization JSONObjectWithData:configData options:0 error:nil];
        IXExpect([config[@"dns"][@"hosts"][@"mainweb.iwur274.f.garqino.ir"] isEqualToString:@"199.232.11.1"], @"dns.hosts keeps the dial IP off vnext");
        NSDictionary *still = [[profile xrayOutbound][@"settings"][@"vnext"] firstObject];
        IXExpect([still[@"address"] isEqualToString:@"mainweb.iwur274.f.garqino.ir"], @"vnext address stays the domain");
        BOOL direct = NO;
        BOOL dnsOut = NO;
        for (NSDictionary *outbound in config[@"outbounds"]) {
            if ([outbound[@"tag"] isEqualToString:@"direct"] && [outbound[@"protocol"] isEqualToString:@"freedom"]) direct = YES;
            if ([outbound[@"tag"] isEqualToString:@"dns-out"] && [outbound[@"protocol"] isEqualToString:@"dns"]) dnsOut = YES;
        }
        IXExpect(direct, @"freedom outbound tagged direct");
        IXExpect(dnsOut, @"dns outbound");
        BOOL dohDirect = NO;
        for (NSDictionary *rule in config[@"routing"][@"rules"]) {
            NSArray *ips = rule[@"ip"];
            if ([rule[@"outboundTag"] isEqualToString:@"direct"] && [ips containsObject:@"1.1.1.1"] && [ips containsObject:@"8.8.8.8"] && [rule[@"port"] isEqualToString:@"443"]) {
                dohDirect = YES;
            }
        }
        IXExpect(dohDirect, @"DoH addresses on 443 route direct");
        BOOL localServer = NO;
        for (id server in config[@"dns"][@"servers"]) {
            if (![server isKindOfClass:[NSDictionary class]]) continue;
            NSArray *domains = server[@"domains"];
            if ([server[@"address"] isEqualToString:@"https+local://1.1.1.1/dns-query"] && [domains containsObject:@"full:mainweb.iwur274.f.garqino.ir"]) {
                localServer = YES;
            }
        }
        IXExpect(localServer, @"proxy domain resolves with https+local");
        NSDictionary *httpIn = nil;
        for (NSDictionary *inbound in config[@"inbounds"]) {
            if ([inbound[@"tag"] isEqualToString:@"http-in"]) httpIn = inbound;
        }
        IXExpect([httpIn[@"sniffing"][@"routeOnly"] isEqual:@YES], @"http-in sniffing is routeOnly");
        IXExpect([httpIn[@"sniffing"][@"destOverride"] containsObject:@"tls"], @"http-in still sniffs tls");

        NSString *xhttpLink =
            @"vless://00000000-0000-0000-0000-000000000000@fs.koomeh.net:443"
            @"?security=tls&type=xhttp"
            @"&host=Kingkingprofosor1.global.ssl.fastly.net"
            @"&sni=ssl.fastly.com&fp=chrome&mode=stream-one&alpn=h2&path=%2F"
            @"&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D";
        IXVLESSProfile *xhttp = [IXVLESSProfile profileFromURI:xhttpLink error:nil];
        NSDictionary *xStream = [xhttp xrayOutbound][@"streamSettings"];
        NSDictionary *xSettings = xStream[@"xhttpSettings"];
        IXExpect([xSettings[@"host"] isEqualToString:@"Kingkingprofosor1.global.ssl.fastly.net"], @"xhttp host");
        IXExpect([xSettings[@"mode"] isEqualToString:@"stream-one"], @"xhttp mode");
        IXExpect([xSettings[@"path"] isEqualToString:@"/"], @"xhttp path");
        IXExpect([xSettings[@"extra"][@"xPaddingBytes"] isEqualToString:@"100-1000"], @"xhttp extra");
        IXExpect([xSettings[@"extra"][@"noGRPCHeader"] isEqual:@YES], @"xhttp noGRPCHeader default");
        IXExpect([xSettings[@"extra"][@"scMaxEachPostBytes"] isEqual:@1000000], @"xhttp scMaxEachPostBytes default");
        IXExpect([xSettings[@"extra"][@"xmux"][@"maxConcurrency"] isEqualToString:@"16-32"], @"xmux default concurrency");
        IXExpect([xSettings[@"extra"][@"xmux"][@"maxConnections"] isEqualToString:@"1-2"], @"xmux default connections");
        IXExpect([xSettings[@"extra"][@"xmux"][@"hMaxRequestTimes"] isEqualToString:@"800-1200"], @"xmux default request reuse");
        IXExpect([xSettings[@"extra"][@"xmux"][@"hKeepAlivePeriod"] isEqual:@15], @"xmux keepalive");
        NSString *xmuxLink =
            @"vless://00000000-0000-0000-0000-000000000000@fs.koomeh.net:443"
            @"?security=tls&type=xhttp&mode=stream-one&path=%2F"
            @"&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%221-2%22%7D%7D";
        IXVLESSProfile *xmuxProfile = [IXVLESSProfile profileFromURI:xmuxLink error:nil];
        NSDictionary *kept = [xmuxProfile xrayOutbound][@"streamSettings"][@"xhttpSettings"][@"extra"][@"xmux"];
        IXExpect([kept[@"maxConcurrency"] isEqualToString:@"1-2"], @"link xmux concurrency is kept");
        IXExpect([kept[@"maxConnections"] isEqualToString:@"1-2"], @"missing xmux keys are filled");
        IXExpect([xStream[@"tlsSettings"][@"serverName"] isEqualToString:@"ssl.fastly.com"], @"xhttp sni");
        IXExpect([xStream[@"tlsSettings"][@"fingerprint"] isEqualToString:@"chrome"], @"xhttp fingerprint");
        IXExpect([xStream[@"tlsSettings"][@"alpn"] isEqual:@[@"h2"]], @"xhttp alpn");
        NSDictionary *xNext = [[xhttp xrayOutbound][@"settings"][@"vnext"] firstObject];
        IXExpect([xNext[@"address"] isEqualToString:@"fs.koomeh.net"], @"xhttp dials the address domain");

        NSString *xhttpBare =
            @"vless://00000000-0000-0000-0000-000000000000@fs.koomeh.net:443"
            @"?security=tls&type=xhttp&host=cdn.example&sni=ssl.fastly.com&path=%2F";
        IXVLESSProfile *bare = [IXVLESSProfile profileFromURI:xhttpBare error:nil];
        IXExpect([[bare xrayOutbound][@"streamSettings"][@"xhttpSettings"][@"mode"] isEqualToString:@"auto"], @"xhttp without mode is sent as auto");
        NSString *autoLink =
            @"vless://00000000-0000-0000-0000-000000000000@fs.koomeh.net:443"
            @"?security=tls&type=xhttp&mode=auto&path=%2F";
        IXVLESSProfile *autoProfile = [IXVLESSProfile profileFromURI:autoLink error:nil];
        IXExpect([autoProfile.mode isEqualToString:@"auto"], @"link mode auto is parsed");
        IXExpect([[autoProfile xrayOutbound][@"streamSettings"][@"xhttpSettings"][@"mode"] isEqualToString:@"auto"], @"xhttp mode auto is sent as auto");
        IXExpect([[IXVLESSProfile xrayXHTTPModeFrom:@"AUTO"] isEqualToString:@"auto"], @"AUTO stays auto");
        autoProfile.outboundInterface = @"en0";
        NSDictionary *bound = [autoProfile xrayOutbound][@"streamSettings"][@"sockopt"];
        IXExpect([bound[@"interface"] isEqualToString:@"en0"], @"proxy dial binds the physical interface");
        NSString *boundJSON = [autoProfile xrayJSONWithSocksPort:1080 httpPort:1081];
        NSDictionary *boundConfig = [NSJSONSerialization JSONObjectWithData:[boundJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        BOOL directBound = NO;
        for (NSDictionary *outbound in boundConfig[@"outbounds"]) {
            if ([outbound[@"tag"] isEqualToString:@"direct"] && [outbound[@"streamSettings"][@"sockopt"][@"interface"] isEqualToString:@"en0"]) directBound = YES;
        }
        IXExpect(directBound, @"direct outbound binds the same interface");
        IXExpect([boundConfig[@"policy"][@"levels"][@"0"][@"uplinkOnly"] isEqual:@120], @"half-close is not cut at 2 seconds");
        IXExpect([boundConfig[@"policy"][@"levels"][@"0"][@"handshake"] isEqual:@15], @"handshake budget is 15 seconds");
        NSString *packet =
            @"vless://00000000-0000-0000-0000-000000000000@fs.koomeh.net:443"
            @"?security=tls&type=xhttp&mode=packet-up&path=%2F";
        IXVLESSProfile *packetProfile = [IXVLESSProfile profileFromURI:packet error:nil];
        IXExpect([[packetProfile xrayOutbound][@"streamSettings"][@"xhttpSettings"][@"mode"] isEqualToString:@"packet-up"], @"explicit packet-up is kept");
        BOOL v6Socks = NO;
        for (NSDictionary *inbound in config[@"inbounds"]) {
            if ([inbound[@"tag"] isEqualToString:@"socks-in6"] && [inbound[@"listen"] isEqualToString:@"::1"]) v6Socks = YES;
        }
        IXExpect(v6Socks, @"ipv6 sockets have a loopback SOCKS inbound");

        NSString *trojan =
            @"trojan://secret@trojan.example:443?security=tls&type=ws&host=cdn.example&path=%2Ftj&sni=sni.example#trojan";
        IXVLESSProfile *trojanProfile = [IXVLESSProfile profileFromURI:trojan error:nil];
        NSDictionary *trojanOut = [trojanProfile xrayOutbound];
        NSDictionary *trojanServer = [trojanOut[@"settings"][@"servers"] firstObject];
        IXExpect([trojanOut[@"protocol"] isEqualToString:@"trojan"], @"trojan protocol");
        IXExpect([trojanServer[@"password"] isEqualToString:@"secret"], @"trojan password");
        IXExpect([trojanServer[@"address"] isEqualToString:@"trojan.example"], @"trojan address");
        IXExpect([trojanOut[@"streamSettings"][@"network"] isEqualToString:@"ws"], @"trojan ws");
        IXExpect([trojanOut[@"streamSettings"][@"wsSettings"][@"host"] isEqualToString:@"cdn.example"], @"trojan ws host");

        NSString *upgrade =
            @"vless://00000000-0000-0000-0000-000000000000@up.example:443?type=httpupgrade&security=tls&path=%2Fup&host=cdn.example&sni=sni.example";
        IXVLESSProfile *upgradeProfile = [IXVLESSProfile profileFromURI:upgrade error:nil];
        NSDictionary *upgradeSettings = [upgradeProfile xrayOutbound][@"streamSettings"][@"httpupgradeSettings"];
        IXExpect([upgradeSettings[@"path"] isEqualToString:@"/up"], @"httpupgrade path");
        IXExpect([upgradeSettings[@"host"] isEqualToString:@"cdn.example"], @"httpupgrade host");

        NSString *grpc =
            @"vless://00000000-0000-0000-0000-000000000000@grpc.example:443?type=grpc&security=tls&serviceName=svc&sni=sni.example";
        IXVLESSProfile *grpcProfile = [IXVLESSProfile profileFromURI:grpc error:nil];
        IXExpect([[grpcProfile xrayOutbound][@"streamSettings"][@"grpcSettings"][@"serviceName"] isEqualToString:@"svc"], @"grpc service");

        NSString *reality =
            @"vless://00000000-0000-0000-0000-000000000000@reality.example:443?security=reality&type=tcp&pbk=PUBLIC&sid=abcd&sni=www.example.com&fp=chrome&flow=xtls-rprx-vision";
        IXVLESSProfile *realityProfile = [IXVLESSProfile profileFromURI:reality error:nil];
        NSDictionary *realitySettings = [realityProfile xrayOutbound][@"streamSettings"][@"realitySettings"];
        IXExpect([realitySettings[@"publicKey"] isEqualToString:@"PUBLIC"], @"reality public key");
        IXExpect([realitySettings[@"shortId"] isEqualToString:@"abcd"], @"reality short id");
        IXExpect([realitySettings[@"serverName"] isEqualToString:@"www.example.com"], @"reality sni");
        IXExpect(realityProfile.needsXray == YES, @"reality needs xray");

        NSDictionary *vmessJSON = @{
            @"v": @"2", @"ps": @"vm", @"add": @"vmess.example", @"port": @"443",
            @"id": @"00000000-0000-0000-0000-000000000000", @"aid": @"0", @"scy": @"auto",
            @"net": @"ws", @"host": @"cdn.example", @"path": @"/vm", @"tls": @"tls", @"sni": @"sni.example"
        };
        NSString *vmessBody = [[NSJSONSerialization dataWithJSONObject:vmessJSON options:0 error:nil] base64EncodedStringWithOptions:0];
        IXVLESSProfile *vmessProfile = [IXVLESSProfile profileFromURI:[@"vmess://" stringByAppendingString:vmessBody] error:nil];
        NSDictionary *vmessOut = [vmessProfile xrayOutbound];
        NSDictionary *vmessNext = [vmessOut[@"settings"][@"vnext"] firstObject];
        NSDictionary *vmessUser = [vmessNext[@"users"] firstObject];
        IXExpect([vmessOut[@"protocol"] isEqualToString:@"vmess"], @"vmess protocol");
        IXExpect([vmessNext[@"address"] isEqualToString:@"vmess.example"], @"vmess address");
        IXExpect([vmessUser[@"security"] isEqualToString:@"auto"], @"vmess security");
        IXExpect([vmessOut[@"streamSettings"][@"wsSettings"][@"path"] isEqualToString:@"/vm"], @"vmess path");

        NSData *ssUser = [@"aes-256-gcm:secret" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *ssLink = [NSString stringWithFormat:@"ss://%@@ss.example:8388?type=tcp#shadow", [ssUser base64EncodedStringWithOptions:0]];
        IXVLESSProfile *ssProfile = [IXVLESSProfile profileFromURI:ssLink error:nil];
        NSDictionary *ssServer = [[ssProfile xrayOutbound][@"settings"][@"servers"] firstObject];
        IXExpect([[ssProfile xrayOutbound][@"protocol"] isEqualToString:@"shadowsocks"], @"ss protocol");
        IXExpect([ssServer[@"method"] isEqualToString:@"aes-256-gcm"], @"ss method");
        IXExpect([ssServer[@"password"] isEqualToString:@"secret"], @"ss password");
        IXExpect([ssServer[@"address"] isEqualToString:@"ss.example"], @"ss address");

        if (gFailures) {
            fprintf(stderr, "%d failure(s)\n%s\n", gFailures, [outbound description].UTF8String);
            return 1;
        }
        printf("vless stream settings ok\n");
        return 0;
    }
}
