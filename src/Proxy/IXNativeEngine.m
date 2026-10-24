#import "IXNativeEngine.h"
#import "IXTrafficGuard.h"

#import <Security/SecureTransport.h>
#import <Security/SecRandom.h>
#import <dlfcn.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>
#import <uuid/uuid.h>

static const uint16_t kIXSocksPort = 61850;
static const uint16_t kIXHTTPPort = 61851;

static NSError *IXNetError(NSString *message) {
    return [NSError errorWithDomain:@"InstagramX.Proxy" code:2 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Proxy error"}];
}

static void IXSetNoSigPipe(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    int idle = 30;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
}

static void IXSetTimeout(int fd, int seconds) {
    struct timeval tv = {.tv_sec = seconds, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static ssize_t IXWriteFull(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        sent += (size_t)n;
    }
    return (ssize_t)sent;
}

static ssize_t IXReadFull(int fd, void *buf, size_t len) {
    uint8_t *p = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n == 0) return 0;
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        got += (size_t)n;
    }
    return (ssize_t)got;
}

#pragma mark - TLS / WebSocket tunnel

typedef struct {
    int fd;
} IXSSLIO;

static OSStatus IXSSLReadFunc(SSLConnectionRef connection, void *data, size_t *dataLength) {
    IXSSLIO *io = (IXSSLIO *)connection;
    size_t want = *dataLength;
    size_t got = 0;
    uint8_t *p = data;
    while (got < want) {
        ssize_t n = recv(io->fd, p + got, want - got, 0);
        if (n > 0) {
            got += (size_t)n;
            *dataLength = got;
            return noErr;
        }
        if (n == 0) {
            *dataLength = got;
            return errSSLClosedGraceful;
        }
        if (errno == EINTR) continue;
        *dataLength = got;
        return errSSLClosedAbort;
    }
    *dataLength = got;
    return noErr;
}

static OSStatus IXSSLWriteFunc(SSLConnectionRef connection, const void *data, size_t *dataLength) {
    IXSSLIO *io = (IXSSLIO *)connection;
    size_t left = *dataLength;
    const uint8_t *p = data;
    size_t sent = 0;
    while (sent < left) {
        ssize_t n = send(io->fd, p + sent, left - sent, 0);
        if (n > 0) {
            sent += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        *dataLength = sent;
        return errSSLClosedAbort;
    }
    *dataLength = sent;
    return noErr;
}

@interface IXTunnel : NSObject
@property (nonatomic) int fd;
@property (nonatomic) SSLContextRef ssl;
@property (nonatomic) IXSSLIO *sslIO;
@property (nonatomic) BOOL websocket;
@property (nonatomic) NSMutableData *wsPending;
- (BOOL)connectProfile:(IXVLESSProfile *)profile error:(NSError **)error;
- (BOOL)readExact:(uint8_t *)buf length:(NSUInteger)len error:(NSError **)error;
- (NSInteger)read:(uint8_t *)buf max:(NSUInteger)maxLen;
- (BOOL)write:(const uint8_t *)buf length:(NSUInteger)len;
- (void)interrupt;
- (void)shutdown;
@end

@implementation IXTunnel

- (instancetype)init {
    self = [super init];
    if (self) {
        _fd = -1;
        _wsPending = [NSMutableData data];
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (BOOL)rawWrite:(const uint8_t *)buf length:(NSUInteger)len error:(NSError **)error {
    if (self.ssl) {
        size_t processed = 0;
        OSStatus st = SSLWrite(self.ssl, buf, len, &processed);
        if (st != noErr || processed != len) {
            if (error) *error = IXNetError([NSString stringWithFormat:@"TLS write failed (%d)", (int)st]);
            return NO;
        }
        return YES;
    }
    if (IXWriteFull(self.fd, buf, len) < 0) {
        if (error) *error = IXNetError(@"Socket write failed.");
        return NO;
    }
    return YES;
}

- (BOOL)rawReadExact:(uint8_t *)buf length:(NSUInteger)len error:(NSError **)error {
    if (self.ssl) {
        size_t got = 0;
        while (got < len) {
            size_t chunk = 0;
            OSStatus st = SSLRead(self.ssl, buf + got, len - got, &chunk);
            got += chunk;
            if (st == noErr) continue;
            if (st == errSSLWouldBlock && chunk > 0) continue;
            if (error) *error = IXNetError([NSString stringWithFormat:@"TLS read failed (%d)", (int)st]);
            return NO;
        }
        return YES;
    }
    if (IXReadFull(self.fd, buf, len) <= 0) {
        if (error) *error = IXNetError(@"Socket closed while reading.");
        return NO;
    }
    return YES;
}

- (BOOL)connectProfile:(IXVLESSProfile *)profile error:(NSError **)error {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    char port[8];
    snprintf(port, sizeof(port), "%u", profile.port);
    struct addrinfo *res = NULL;
    int gai = IXOrigGetaddrinfo(profile.host.UTF8String, port, &hints, &res);
    if (gai != 0 || !res) {
        if (error) *error = IXNetError([NSString stringWithFormat:@"Could not resolve %@", profile.host]);
        return NO;
    }

    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        IXSetNoSigPipe(fd);
        IXSetTimeout(fd, 20);
        if (IXOrigConnect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        if (error) *error = IXNetError([NSString stringWithFormat:@"Could not connect to %@:%u", profile.host, profile.port]);
        return NO;
    }
    self.fd = fd;

    if ([profile.security isEqualToString:@"tls"]) {
        SSLContextRef ssl = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
        self.sslIO = calloc(1, sizeof(IXSSLIO));
        self.sslIO->fd = fd;
        SSLSetIOFuncs(ssl, IXSSLReadFunc, IXSSLWriteFunc);
        SSLSetConnection(ssl, self.sslIO);
        NSString *sni = profile.sni.length ? profile.sni : profile.host;
        SSLSetPeerDomainName(ssl, sni.UTF8String, strlen(sni.UTF8String));
        if (profile.allowInsecure) {
            SSLSetSessionOption(ssl, kSSLSessionOptionBreakOnServerAuth, true);
        }
        OSStatus (*setALPN)(SSLContextRef, CFArrayRef) = dlsym(RTLD_DEFAULT, "SSLSetALPNProtocols");
        if (setALPN) {
            setALPN(ssl, (__bridge CFArrayRef)@[@"http/1.1"]);
        }
        OSStatus st;
        do {
            st = SSLHandshake(ssl);
            if (st == errSSLServerAuthCompleted && profile.allowInsecure) continue;
        } while (st == errSSLWouldBlock || (st == errSSLServerAuthCompleted && profile.allowInsecure));
        if (st != noErr) {
            CFRelease(ssl);
            if (error) *error = IXNetError([NSString stringWithFormat:@"TLS handshake failed (%d). REALITY and uTLS fingerprints need the Xray build.", (int)st]);
            return NO;
        }
        self.ssl = ssl;
    } else if (![profile.security isEqualToString:@"none"]) {
        if (error) *error = IXNetError(@"This security mode needs the Xray engine.");
        return NO;
    }

    if ([profile.network isEqualToString:@"ws"]) {
        if (![self openWebSocket:profile error:error]) return NO;
        self.websocket = YES;
    } else if (![profile.network isEqualToString:@"tcp"]) {
        if (error) *error = IXNetError(@"This transport needs the Xray engine.");
        return NO;
    }
    return YES;
}

- (BOOL)openWebSocket:(IXVLESSProfile *)profile error:(NSError **)error {
    uint8_t random[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(random), random) != errSecSuccess) {
        arc4random_buf(random, sizeof(random));
    }
    NSString *key = [[NSData dataWithBytes:random length:sizeof(random)] base64EncodedStringWithOptions:0];
    NSString *hostHeader = profile.wsHost.length ? profile.wsHost : (profile.sni.length ? profile.sni : profile.host);
    NSString *path = profile.path.length ? profile.path : @"/";
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    NSString *req = [NSString stringWithFormat:
                     @"GET %@ HTTP/1.1\r\n"
                     @"Host: %@\r\n"
                     @"Upgrade: websocket\r\n"
                     @"Connection: Upgrade\r\n"
                     @"Sec-WebSocket-Key: %@\r\n"
                     @"Sec-WebSocket-Version: 13\r\n"
                     @"\r\n", path, hostHeader, key];
    NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];
    if (![self rawWrite:reqData.bytes length:reqData.length error:error]) return NO;

    NSMutableData *header = [NSMutableData data];
    uint8_t byte;
    while (header.length < 8192) {
        if (![self rawReadExact:&byte length:1 error:error]) return NO;
        [header appendBytes:&byte length:1];
        if (header.length >= 4) {
            const uint8_t *b = header.bytes;
            if (b[header.length - 4] == '\r' && b[header.length - 3] == '\n' && b[header.length - 2] == '\r' && b[header.length - 1] == '\n') break;
        }
    }
    NSString *text = [[NSString alloc] initWithData:header encoding:NSUTF8StringEncoding] ?: @"";
    if (![text hasPrefix:@"HTTP/1.1 101"] && ![text hasPrefix:@"HTTP/1.0 101"]) {
        if (error) *error = IXNetError(@"WebSocket upgrade was rejected.");
        return NO;
    }
    return YES;
}

- (BOOL)writeWSFrame:(const uint8_t *)buf length:(NSUInteger)len error:(NSError **)error {
    NSMutableData *frame = [NSMutableData dataWithCapacity:len + 14];
    uint8_t header[14];
    size_t hlen = 0;
    header[0] = 0x82;
    if (len < 126) {
        header[1] = 0x80 | (uint8_t)len;
        hlen = 2;
    } else if (len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        header[2] = (len >> 8) & 0xff;
        header[3] = len & 0xff;
        hlen = 4;
    } else {
        header[1] = 0x80 | 127;
        uint64_t n = (uint64_t)len;
        for (int i = 0; i < 8; i++) header[2 + i] = (n >> (56 - 8 * i)) & 0xff;
        hlen = 10;
    }
    uint8_t mask[4];
    arc4random_buf(mask, 4);
    memcpy(header + hlen, mask, 4);
    hlen += 4;
    [frame appendBytes:header length:hlen];
    for (NSUInteger i = 0; i < len; i++) {
        uint8_t b = buf[i] ^ mask[i & 3];
        [frame appendBytes:&b length:1];
    }
    return [self rawWrite:frame.bytes length:frame.length error:error];
}

- (BOOL)readWSPayloadIntoPending:(NSError **)error {
    uint8_t hdr[2];
    if (![self rawReadExact:hdr length:2 error:error]) return NO;
    uint8_t opcode = hdr[0] & 0x0f;
    BOOL masked = (hdr[1] & 0x80) != 0;
    uint64_t len = hdr[1] & 0x7f;
    if (len == 126) {
        uint8_t ext[2];
        if (![self rawReadExact:ext length:2 error:error]) return NO;
        len = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (len == 127) {
        uint8_t ext[8];
        if (![self rawReadExact:ext length:8 error:error]) return NO;
        len = 0;
        for (int i = 0; i < 8; i++) len = (len << 8) | ext[i];
    }
    if (len > 8 * 1024 * 1024) {
        if (error) *error = IXNetError(@"WebSocket frame is too large.");
        return NO;
    }
    uint8_t mask[4] = {0};
    if (masked && ![self rawReadExact:mask length:4 error:error]) return NO;
    NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)len];
    if (len && ![self rawReadExact:payload.mutableBytes length:(NSUInteger)len error:error]) return NO;
    if (masked) {
        uint8_t *p = payload.mutableBytes;
        for (uint64_t i = 0; i < len; i++) p[i] ^= mask[i & 3];
    }
    if (opcode == 0x8) {
        if (error) *error = IXNetError(@"WebSocket closed.");
        return NO;
    }
    if (opcode == 0x9) {
        // Ping. Reply with the same payload as a pong, then keep reading.
        NSMutableData *pong = [NSMutableData data];
        uint8_t b0 = 0x8A;
        [pong appendBytes:&b0 length:1];
        uint8_t b1 = 0x80 | (uint8_t)MIN(payload.length, (NSUInteger)125);
        [pong appendBytes:&b1 length:1];
        uint8_t pmask[4];
        arc4random_buf(pmask, 4);
        [pong appendBytes:pmask length:4];
        const uint8_t *src = payload.bytes;
        for (NSUInteger i = 0; i < payload.length && i < 125; i++) {
            uint8_t x = src[i] ^ pmask[i & 3];
            [pong appendBytes:&x length:1];
        }
        [self rawWrite:pong.bytes length:pong.length error:nil];
        return [self readWSPayloadIntoPending:error];
    }
    if (opcode == 0xA) return [self readWSPayloadIntoPending:error];
    [self.wsPending appendData:payload];
    return YES;
}

- (void)interrupt {
    if (self.fd >= 0) shutdown(self.fd, SHUT_RDWR);
}

- (BOOL)write:(const uint8_t *)buf length:(NSUInteger)len {
    if (!len) return YES;
    if (self.websocket) return [self writeWSFrame:buf length:len error:nil];
    return [self rawWrite:buf length:len error:nil];
}

- (NSInteger)read:(uint8_t *)buf max:(NSUInteger)maxLen {
    if (self.websocket) {
        if (self.wsPending.length == 0) {
            if (![self readWSPayloadIntoPending:nil]) return -1;
        }
        NSUInteger n = MIN(maxLen, self.wsPending.length);
        memcpy(buf, self.wsPending.bytes, n);
        [self.wsPending replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
        return (NSInteger)n;
    }
    if (self.ssl) {
        size_t got = 0;
        OSStatus st = SSLRead(self.ssl, buf, maxLen, &got);
        if (got > 0) return (NSInteger)got;
        if (st == errSSLClosedGraceful || st == errSSLClosedNoNotify) return 0;
        return -1;
    }
    ssize_t n = recv(self.fd, buf, maxLen, 0);
    return (NSInteger)n;
}

- (BOOL)readExact:(uint8_t *)buf length:(NSUInteger)len error:(NSError **)error {
    NSUInteger got = 0;
    while (got < len) {
        NSInteger n = [self read:buf + got max:len - got];
        if (n <= 0) {
            if (error) *error = IXNetError(@"Connection closed.");
            return NO;
        }
        got += (NSUInteger)n;
    }
    return YES;
}

- (BOOL)writeVLESSToHost:(NSString *)host port:(uint16_t)port uuid:(NSString *)uuid error:(NSError **)error {
    NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:uuid];
    if (!parsed) {
        if (error) *error = IXNetError(@"Invalid VLESS UUID.");
        return NO;
    }
    uuid_t bytes;
    [parsed getUUIDBytes:bytes];

    NSMutableData *header = [NSMutableData data];
    uint8_t ver = 0;
    [header appendBytes:&ver length:1];
    [header appendBytes:bytes length:16];
    uint8_t addon = 0;
    [header appendBytes:&addon length:1];
    uint8_t cmd = 1;
    [header appendBytes:&cmd length:1];
    uint16_t bePort = htons(port);
    [header appendBytes:&bePort length:2];

    struct in_addr v4;
    struct in6_addr v6;
    if (inet_pton(AF_INET, host.UTF8String, &v4) == 1) {
        uint8_t atyp = 1;
        [header appendBytes:&atyp length:1];
        [header appendBytes:&v4 length:4];
    } else if (inet_pton(AF_INET6, host.UTF8String, &v6) == 1) {
        uint8_t atyp = 3;
        [header appendBytes:&atyp length:1];
        [header appendBytes:&v6 length:16];
    } else {
        NSData *name = [host dataUsingEncoding:NSUTF8StringEncoding];
        if (name.length == 0 || name.length > 255) {
            if (error) *error = IXNetError(@"Destination host is too long.");
            return NO;
        }
        uint8_t atyp = 2;
        uint8_t nlen = (uint8_t)name.length;
        [header appendBytes:&atyp length:1];
        [header appendBytes:&nlen length:1];
        [header appendData:name];
    }
    if (![self write:header.bytes length:header.length]) {
        if (error) *error = IXNetError(@"Could not write the VLESS header.");
        return NO;
    }

    uint8_t resp[2];
    if (![self readExact:resp length:2 error:error]) return NO;
    uint8_t addonLen = resp[1];
    if (addonLen) {
        uint8_t sink[256];
        // addonLen is a single byte, so it always fits in sink.
        if (![self readExact:sink length:addonLen error:error]) {
            if (error && !*error) *error = IXNetError(@"Unexpected VLESS addon.");
            return NO;
        }
    }
    return YES;
}

- (void)shutdown {
    if (self.ssl) {
        SSLClose(self.ssl);
        CFRelease(self.ssl);
        self.ssl = NULL;
    }
    if (self.sslIO) {
        free(self.sslIO);
        self.sslIO = NULL;
    }
    if (self.fd >= 0) {
        close(self.fd);
        self.fd = -1;
    }
}

@end

#pragma mark - Listener

@implementation IXNativeEngine {
    int _socksFD;
    int _httpFD;
    BOOL _running;
    IXVLESSProfile *_profile;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _socksFD = -1;
        _httpFD = -1;
        _queue = dispatch_queue_create("instagramx.vless", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (uint16_t)socksPort { return kIXSocksPort; }
- (uint16_t)httpPort { return kIXHTTPPort; }
- (BOOL)isRunning { return _running; }

- (int)listenOnPort:(uint16_t)port error:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = IXNetError(@"Could not open a local socket.");
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    IXSetNoSigPipe(fd);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 128) != 0) {
        close(fd);
        if (error) *error = IXNetError([NSString stringWithFormat:@"127.0.0.1:%u is already in use.", port]);
        return -1;
    }
    return fd;
}

- (BOOL)startWithProfile:(IXVLESSProfile *)profile error:(NSError **)error {
    [self stop];
    if (profile.needsXray) {
        if (error) *error = IXNetError(@"This link uses REALITY, Vision, gRPC, or another transport the built-in engine does not speak. Install a build that includes Xray.");
        return NO;
    }
    NSError *listenError = nil;
    int socks = [self listenOnPort:kIXSocksPort error:&listenError];
    if (socks < 0) {
        if (error) *error = listenError;
        return NO;
    }
    int http = [self listenOnPort:kIXHTTPPort error:&listenError];
    if (http < 0) {
        close(socks);
        if (error) *error = listenError;
        return NO;
    }
    _profile = [profile copy];
    _socksFD = socks;
    _httpFD = http;
    _running = YES;
    [self acceptLoop:socks http:NO];
    [self acceptLoop:http http:YES];
    return YES;
}

- (void)acceptLoop:(int)listenFD http:(BOOL)http {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (self->_running && self->_socksFD >= 0) {
            struct sockaddr_in client;
            socklen_t len = sizeof(client);
            int fd = accept(listenFD, (struct sockaddr *)&client, &len);
            if (fd < 0) {
                if (errno == EINTR) continue;
                if (!self->_running) break;
                continue;
            }
            IXSetNoSigPipe(fd);
            IXSetTimeout(fd, 120);
            dispatch_async(self->_queue, ^{
                if (http) [self handleHTTP:fd];
                else [self handleSOCKS:fd];
            });
        }
    });
}

- (void)stop {
    _running = NO;
    if (_socksFD >= 0) {
        close(_socksFD);
        _socksFD = -1;
    }
    if (_httpFD >= 0) {
        close(_httpFD);
        _httpFD = -1;
    }
    _profile = nil;
}

- (IXTunnel *)openTunnelToHost:(NSString *)host port:(uint16_t)port {
    if (!_running || !_profile) return nil;
    IXTunnel *tunnel = [IXTunnel new];
    NSError *error = nil;
    if (![tunnel connectProfile:_profile error:&error]) {
        NSLog(@"[InstagramX] VLESS dial failed: %@", error.localizedDescription);
        [tunnel shutdown];
        return nil;
    }
    if (![tunnel writeVLESSToHost:host port:port uuid:_profile.uuid error:&error]) {
        NSLog(@"[InstagramX] VLESS header failed: %@", error.localizedDescription);
        [tunnel shutdown];
        return nil;
    }
    return tunnel;
}

- (void)spliceClient:(int)client withTunnel:(IXTunnel *)tunnel {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_queue_t io = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    dispatch_async(io, ^{
        uint8_t buf[16384];
        while (1) {
            ssize_t n = recv(client, buf, sizeof(buf), 0);
            if (n <= 0) break;
            if (![tunnel write:buf length:(NSUInteger)n]) break;
        }
        [tunnel interrupt];
        dispatch_semaphore_signal(done);
    });
    dispatch_async(io, ^{
        uint8_t buf[16384];
        while (1) {
            NSInteger n = [tunnel read:buf max:sizeof(buf)];
            if (n <= 0) break;
            if (IXWriteFull(client, buf, (size_t)n) < 0) break;
        }
        shutdown(client, SHUT_RDWR);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    [tunnel shutdown];
    close(client);
}

- (void)socksFail:(int)fd {
    uint8_t reply[10] = {0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    IXWriteFull(fd, reply, sizeof(reply));
    close(fd);
}

- (void)handleSOCKS:(int)fd {
    uint8_t hello[2];
    if (IXReadFull(fd, hello, 2) <= 0 || hello[0] != 0x05) {
        close(fd);
        return;
    }
    uint8_t methods[256];
    if (hello[1] && IXReadFull(fd, methods, hello[1]) <= 0) {
        close(fd);
        return;
    }
    uint8_t methodReply[2] = {0x05, 0x00};
    if (IXWriteFull(fd, methodReply, 2) < 0) {
        close(fd);
        return;
    }
    uint8_t req[4];
    if (IXReadFull(fd, req, 4) <= 0 || req[0] != 0x05 || req[1] != 0x01) {
        [self socksFail:fd];
        return;
    }
    NSString *host = nil;
    uint16_t port = 0;
    if (req[3] == 0x01) {
        uint8_t ip[4];
        uint8_t p[2];
        if (IXReadFull(fd, ip, 4) <= 0 || IXReadFull(fd, p, 2) <= 0) {
            close(fd);
            return;
        }
        char text[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, ip, text, sizeof(text));
        host = [NSString stringWithUTF8String:text];
        port = (uint16_t)((p[0] << 8) | p[1]);
    } else if (req[3] == 0x03) {
        uint8_t nlen = 0;
        if (IXReadFull(fd, &nlen, 1) <= 0) {
            close(fd);
            return;
        }
        char name[256];
        uint8_t p[2];
        if (IXReadFull(fd, name, nlen) <= 0 || IXReadFull(fd, p, 2) <= 0) {
            close(fd);
            return;
        }
        name[nlen] = 0;
        host = [NSString stringWithUTF8String:name];
        port = (uint16_t)((p[0] << 8) | p[1]);
    } else if (req[3] == 0x04) {
        uint8_t ip[16];
        uint8_t p[2];
        if (IXReadFull(fd, ip, 16) <= 0 || IXReadFull(fd, p, 2) <= 0) {
            close(fd);
            return;
        }
        char text[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, ip, text, sizeof(text));
        host = [NSString stringWithUTF8String:text];
        port = (uint16_t)((p[0] << 8) | p[1]);
    } else {
        [self socksFail:fd];
        return;
    }

    // Fake addresses assigned by the DNS hook carry the original hostname.
    NSString *mapped = IXTrafficGuardLookupHost(host);
    if (mapped.length) host = mapped;

    IXTunnel *tunnel = [self openTunnelToHost:host port:port];
    if (!tunnel) {
        [self socksFail:fd];
        return;
    }
    uint8_t ok[10] = {0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    if (IXWriteFull(fd, ok, sizeof(ok)) < 0) {
        [tunnel shutdown];
        close(fd);
        return;
    }
    [self spliceClient:fd withTunnel:tunnel];
}

- (void)handleHTTP:(int)fd {
    NSMutableData *header = [NSMutableData data];
    uint8_t byte;
    while (header.length < 16384) {
        ssize_t n = recv(fd, &byte, 1, 0);
        if (n <= 0) {
            close(fd);
            return;
        }
        [header appendBytes:&byte length:1];
        if (header.length >= 4) {
            const uint8_t *b = header.bytes;
            if (b[header.length - 4] == '\r' && b[header.length - 3] == '\n' && b[header.length - 2] == '\r' && b[header.length - 1] == '\n') break;
        }
    }
    NSString *text = [[NSString alloc] initWithData:header encoding:NSUTF8StringEncoding];
    NSString *first = [[text componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";
    NSArray *parts = [first componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        close(fd);
        return;
    }
    NSString *method = parts[0];
    NSString *target = parts[1];
    NSString *host = nil;
    uint16_t port = 80;
    if ([method caseInsensitiveCompare:@"CONNECT"] == NSOrderedSame) {
        NSArray *hp = [target componentsSeparatedByString:@":"];
        host = hp.firstObject;
        if (hp.count > 1) port = (uint16_t)[hp[1] intValue];
        if (!port) port = 443;
    } else {
        NSURL *url = [NSURL URLWithString:target];
        host = url.host;
        port = url.port ? url.port.unsignedShortValue : ([url.scheme isEqualToString:@"https"] ? 443 : 80);
    }
    NSString *mapped = IXTrafficGuardLookupHost(host);
    if (mapped.length) host = mapped;
    if (host.length == 0) {
        close(fd);
        return;
    }
    IXTunnel *tunnel = [self openTunnelToHost:host port:port];
    if (!tunnel) {
        const char *denied = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n";
        IXWriteFull(fd, denied, strlen(denied));
        close(fd);
        return;
    }
    if ([method caseInsensitiveCompare:@"CONNECT"] == NSOrderedSame) {
        const char *ok = "HTTP/1.1 200 Connection Established\r\n\r\n";
        if (IXWriteFull(fd, ok, strlen(ok)) < 0) {
            [tunnel shutdown];
            close(fd);
            return;
        }
    } else if (![tunnel write:header.bytes length:header.length]) {
        [tunnel shutdown];
        close(fd);
        return;
    }
    [self spliceClient:fd withTunnel:tunnel];
}

@end
