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

        if (gFailures) {
            fprintf(stderr, "%d failure(s)\n%s\n", gFailures, [outbound description].UTF8String);
            return 1;
        }
        printf("vless stream settings ok\n");
        return 0;
    }
}
