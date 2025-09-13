#import "socks.h"
#import "channel.h"

NSMutableDictionary *sockets;
dispatch_queue_t socketsQ;

@interface AddrSpec : NSObject
@property (nonatomic, copy, nullable) NSString *FQDN;
@property (nonatomic, copy, nullable) NSString *IP;
@property (nonatomic) uint16_t Port;
@end
@implementation AddrSpec @end

static const uint8_t kSocks5Version = 0x05;
static const uint8_t kATYPIPv4      = 0x01;
static const uint8_t kATYPFQDN      = 0x03;
static const uint8_t kATYPIPv6      = 0x04;

typedef NS_ENUM(uint8_t, SocksReply) {
    SocksReplySuccess = 0,
    SocksReplyServerFailure,
    SocksReplyRuleFailure,
    SocksReplyNetworkUnreachable,
    SocksReplyHostUnreachable,
    SocksReplyConnectionRefused,
    SocksReplyTtlExpired,
    SocksReplyCommandNotSupported,
    SocksReplyAddrTypeNotSupported
};

void InitSocks(void) {
    socketsQ = dispatch_queue_create("socks.table", DISPATCH_QUEUE_SERIAL);
    sockets = [NSMutableDictionary dictionary];
}

// Always return VER|REP|RSV|ATYP|BND.ADDR|BND.PORT
static NSData * buildReply(uint8_t rep, AddrSpec * _Nullable addr) {
    uint8_t  addrType = kATYPIPv4;
    NSData  *addrBody = nil;
    uint16_t addrPort = 0;

    if (!addr) {
        uint8_t zero[4] = {0,0,0,0};
        addrBody = [NSData dataWithBytes:zero length:4];
    } else if (addr.FQDN.length > 0) {
        NSData *fqdn = [addr.FQDN dataUsingEncoding:NSUTF8StringEncoding];
        if (!fqdn || fqdn.length > 255) {
            uint8_t zero[4] = {0,0,0,0};
            addrBody = [NSData dataWithBytes:zero length:4];
        } else {
            NSMutableData *m = [NSMutableData dataWithCapacity:1 + fqdn.length];
            uint8_t len = (uint8_t)fqdn.length;
            [m appendBytes:&len length:1];
            [m appendData:fqdn];
            addrType = kATYPFQDN;
            addrBody = m;
            addrPort = addr.Port;
        }
    } else if (addr.IP.length > 0) {
        struct in_addr  v4;  memset(&v4, 0, sizeof v4);
        struct in6_addr v6;  memset(&v6, 0, sizeof v6);
        if (inet_pton(AF_INET, addr.IP.UTF8String, &v4) == 1) {
            addrType = kATYPIPv4;
            addrBody = [NSData dataWithBytes:&v4 length:4];
            addrPort = addr.Port;
        } else if (inet_pton(AF_INET6, addr.IP.UTF8String, &v6) == 1) {
            addrType = kATYPIPv6;
            addrBody = [NSData dataWithBytes:&v6 length:16];
            addrPort = addr.Port;
        } else {
            uint8_t zero[4] = {0,0,0,0};
            addrBody = [NSData dataWithBytes:zero length:4];
        }
    } else {
        uint8_t zero[4] = {0,0,0,0};
        addrBody = [NSData dataWithBytes:zero length:4];
    }

    NSMutableData *msg = [NSMutableData dataWithCapacity:6 + addrBody.length];
    const uint8_t header[4] = { kSocks5Version, rep, 0x00, addrType };
    [msg appendBytes:header length:sizeof header];
    [msg appendData:addrBody];
    uint8_t p[2] = { (uint8_t)(addrPort >> 8), (uint8_t)(addrPort & 0xFF) };
    [msg appendBytes:p length:2];
    return msg;
}

NSString *IPv4StringFromStream(NSInputStream *stream) {
    uint8_t raw[4];
    NSInteger n = [stream read:raw maxLength:sizeof(raw)];
    if (n != sizeof(raw)) return nil;
    char ip[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET, raw, ip, sizeof(ip))) return nil;
    return [NSString stringWithUTF8String:ip];
}

uint16_t PortFromStream(NSInputStream *stream) {
    uint8_t b[2]; if ([stream read:b maxLength:2] != 2) return 0;
    return (uint16_t)((b[0] << 8) | b[1]);
}

NSString *IPv6StringFromStream(NSInputStream *stream) {
    uint8_t raw[16];
    NSInteger n = [stream read:raw maxLength:sizeof(raw)];
    if (n != sizeof(raw)) return nil;
    char ip[INET6_ADDRSTRLEN];
    if (!inet_ntop(AF_INET6, raw, ip, sizeof(ip))) return nil;
    return [NSString stringWithUTF8String:ip];
}

NSString *FQDNStringFromStream(NSInputStream *stream) {
    uint8_t len;
    NSInteger n = [stream read:&len maxLength:1];
    if (n != 1) return nil;
    if (len == 0) return nil;

    uint8_t *buf = malloc(len);
    if (!buf) return nil;
    n = [stream read:buf maxLength:len];
    if (n != len) { free(buf); return nil; }

    NSString *host = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    free(buf);
    return host;
}

NSString *ResolveDNS(NSString *host) {
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
#if defined(AI_ADDRCONFIG)
    hints.ai_flags    = AI_ADDRCONFIG;
#endif
    int err = getaddrinfo(host.UTF8String, NULL, &hints, &res);
    if (err != 0) {
        NSLog(@"getaddrinfo error: %s", gai_strerror(err));
        return nil;
    }

    NSString *ipString = nil;
    for (struct addrinfo *p = res; p; p = p->ai_next) {
        char buf[INET6_ADDRSTRLEN] = {0};
        void *addr = NULL;
        if (p->ai_family == AF_INET) {
            addr = &((struct sockaddr_in *)p->ai_addr)->sin_addr;
        } else if (p->ai_family == AF_INET6) {
            addr = &((struct sockaddr_in6 *)p->ai_addr)->sin6_addr;
        } else {
            continue;
        }
        if (inet_ntop(p->ai_family, addr, buf, sizeof(buf))) {
            ipString = [NSString stringWithUTF8String:buf];
            break;
        }
    }
    freeaddrinfo(res);
    return ipString;
}

static AddrSpec * _Nullable LocalAddrSpecFromInputStream(NSInputStream *in) {
    CFDataRef d = CFReadStreamCopyProperty((__bridge CFReadStreamRef)in, kCFStreamPropertySocketNativeHandle);
    if (!d) return nil;
    CFSocketNativeHandle fd = -1;
    CFDataGetBytes(d, CFRangeMake(0, sizeof(fd)), (UInt8 *)&fd);
    CFRelease(d);
    if (fd < 0) return nil;

    struct sockaddr_storage ss; socklen_t len = sizeof(ss);
    if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0) return nil;

    char host[INET6_ADDRSTRLEN] = {0}; uint16_t port = 0;
    if (ss.ss_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ss;
        inet_ntop(AF_INET, &sin->sin_addr, host, sizeof(host));
        port = ntohs(sin->sin_port);
    } else if (ss.ss_family == AF_INET6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&ss;
        inet_ntop(AF_INET6, &sin6->sin6_addr, host, sizeof(host));
        port = ntohs(sin6->sin6_port);
    } else { return nil; }

    AddrSpec *a = [AddrSpec new];
    a.IP = [NSString stringWithUTF8String:host];
    a.Port = port;
    return a;
}

static BOOL AddrSpecHasIpAndPort(AddrSpec *a) {
    if (!a) return NO;
    if (a.IP == nil || a.IP.length == 0) return NO;
    if (a.Port == 0) return NO;
    return YES;
}

static void closeSocket(NSNumber *serverId) {
    NSLog(@"closeSocket(): start server_id=%@", serverId);
    __block NSInputStream  *in  = nil;
    __block NSOutputStream *out = nil;
    dispatch_sync(socketsQ, ^{
        NSDictionary *pair = sockets[serverId];
        in  = (NSInputStream  *)pair[@"in"];
        out = (NSOutputStream *)pair[@"out"];
    });
    if (!in && !out) return;

    if (in) {
        CFReadStreamSetProperty((__bridge CFReadStreamRef)in, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    }
    if (out) {
        CFWriteStreamSetProperty((__bridge CFWriteStreamRef)out, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    }

    in.delegate = nil;
    out.delegate = nil;
    [in close];
    [out close];

    dispatch_async(socketsQ, ^{
        NSDictionary *cur = sockets[serverId];
        if (!cur) return;
        NSInputStream  *curIn  = cur[@"in"];
        NSOutputStream *curOut = cur[@"out"];
        if (curIn == in && curOut == out) {
            [sockets removeObjectForKey:serverId];
        }
    });
    NSLog(@"closeSocket(): end server_id=%@", serverId);
}

void writeToProxy(NSNumber *serverId, NSData *data) {
    __block NSDictionary *pair;
    dispatch_sync(socketsQ, ^{ pair = sockets[serverId]; });
    NSOutputStream *out = pair[@"out"];
    dispatch_queue_t q  = pair[@"q"];
    if (!out || !q) {
        NSLog(@"writeToProxy(): socket not found server_id=%@", serverId);
        return;
    }

    dispatch_async(q, ^{
        const uint8_t *bytes = data.bytes;
        NSUInteger total = data.length, offset = 0;

        while (offset < total) {
            if (out.streamStatus == NSStreamStatusError || out.streamStatus == NSStreamStatusClosed) {
                NSLog(@"writeToProxy(): stream error/closed server_id=%@", serverId);
                AddResponse([@{@"server_id": serverId, @"data":@"", @"exit":@YES} mutableCopy]);
                closeSocket(serverId);
                return;
            }
            NSInteger n = [out write:bytes + offset maxLength:(total - offset)];
            if (n > 0) {
                offset += (NSUInteger)n;
            } else if (n == 0) {
                usleep(10 * 1000);
            } else {
                NSLog(@"writeToProxy(): write error server_id=%@", serverId);
                AddResponse([@{@"server_id": serverId, @"data":@"", @"exit":@YES} mutableCopy]);
                closeSocket(serverId);
                return;
            }
        }
    });
}

static void readFromProxy(NSNumber *serverId) {
    NSLog(@"readFromProxy(): start server_id=%@", serverId);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block NSInputStream *in = nil;
        dispatch_sync(socketsQ, ^{
            NSDictionary *pair = sockets[serverId];
            in = (NSInputStream *)pair[@"in"];
        });
        if (!in) {
            NSLog(@"readFromProxy(): socket not found");
            return;
        }

        NSMutableData *accumulated = [NSMutableData data];
        uint8_t buf[4096];

        for (;;) {
            NSInteger n = [in read:buf maxLength:sizeof(buf)];
            if (n > 0) {
                [accumulated appendBytes:buf length:(NSUInteger)n];

                BOOL more = [in hasBytesAvailable];
                if (!more) {
                    usleep(50 * 1000);
                    more = [in hasBytesAvailable];
                }

                if (!more || accumulated.length >= 8192) {
                    NSString *b64 = [accumulated base64EncodedStringWithOptions:0];
                    AddResponse(@{@"server_id": serverId, @"data": b64, @"exit": @NO});
                    [accumulated setLength:0];
                }
            } else if (n == 0) {
                if (accumulated.length > 0) {
                    NSString *b64 = [accumulated base64EncodedStringWithOptions:0];
                    AddResponse(@{@"server_id": serverId, @"data": b64, @"exit": @NO});
                }
                AddResponse(@{@"server_id": serverId, @"data": @"", @"exit": @YES});
                closeSocket(serverId);
                return;
            } else {
                AddResponse(@{@"server_id": serverId, @"data": @"", @"exit": @YES});
                closeSocket(serverId);
                return;
            }

            usleep(10 * 1000);
        }
    });
}

static BOOL WaitForOpen(NSInputStream *in, NSOutputStream *out, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    for (;;) {
        NSStreamStatus si = in.streamStatus, so = out.streamStatus;
        if ((si == NSStreamStatusOpen || si == NSStreamStatusReading) &&
            (so == NSStreamStatusOpen || so == NSStreamStatusWriting)) {
            return YES;
        }
        if (si == NSStreamStatusError || so == NSStreamStatusError) return NO;
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        usleep(20 * 1000);
    }
}

void connectToProxy(NSNumber *serverId, NSData *data) {
    NSLog(@"connectToProxy(): start server_id=%@", serverId);
    NSInputStream *stream = [[NSInputStream alloc] initWithData:data];
    [stream open];

    uint8_t header[3];
    NSInteger readBytes = [stream read:header maxLength:3];
    if (readBytes < 3) {
        NSData* msg = buildReply(SocksReplyServerFailure, nil);
        AddResponse([@{@"server_id": serverId, @"data": [msg base64EncodedStringWithOptions:0], @"exit": @YES} mutableCopy]);
        [stream close];
        return;
    }

    if (header[0] != kSocks5Version) {
        AddResponse([@{@"server_id": serverId, @"data": @"", @"exit": @YES} mutableCopy]);
        [stream close];
        return;
    }

    if (header[1] == 0x1) {
        if (header[2] != 0x00) {
            NSData* msg = buildReply(SocksReplyCommandNotSupported, nil);
            AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
            [stream close];
            return;
        }

        uint8_t type;
        if ([stream read:&type maxLength:1] != 1) {
            NSData* msg = buildReply(SocksReplyServerFailure, nil);
            AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
            [stream close];
            return;
        }

        AddrSpec *a = [AddrSpec new];
        switch (type) {
            case 0x1:
                a.IP = IPv4StringFromStream(stream);
                break;
            case 0x3:
                a.FQDN = FQDNStringFromStream(stream);
                if (!a.FQDN) {
                    NSData* msg = buildReply(SocksReplyAddrTypeNotSupported, nil);
                    AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
                    [stream close];
                    return;
                }
                a.IP = ResolveDNS(a.FQDN);
                if (a.IP == nil) {
                    NSData* msg = buildReply(SocksReplyNetworkUnreachable, nil);
                    AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
                    [stream close];
                    return;
                }
                break;
            case 0x4:
                a.IP = IPv6StringFromStream(stream);
                break;
            default: {
                NSData* msg = buildReply(SocksReplyAddrTypeNotSupported, nil);
                AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
                [stream close];
                return;
            }
        }

        a.Port = PortFromStream(stream);
        if (!AddrSpecHasIpAndPort(a)) {
            NSData* msg = buildReply(SocksReplyAddrTypeNotSupported, nil);
            AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
            [stream close];
            return;
        }

        CFReadStreamRef r = NULL;
        CFWriteStreamRef w = NULL;
        CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)a.IP, a.Port, &r, &w);
        NSInputStream  *in  = CFBridgingRelease(r);
        NSOutputStream *out = CFBridgingRelease(w);
        if (!in || !out) {
            NSData* msg = buildReply(SocksReplyServerFailure, nil);
            AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
            [stream close];
            return;
        }

        [in open];
        [out open];

        if (!WaitForOpen(in, out, 5.0)) {
            NSError *errNow = in.streamError ?: out.streamError;
            uint8_t reason = SocksReplyServerFailure;
            if ([errNow.domain isEqualToString:NSPOSIXErrorDomain]) {
                switch (errNow.code) {
                    case ECONNREFUSED: reason = SocksReplyConnectionRefused; break;
                    case ENETUNREACH:  reason = SocksReplyNetworkUnreachable; break;
                    case EHOSTUNREACH: reason = SocksReplyHostUnreachable;   break;
                    case ETIMEDOUT:    reason = SocksReplyTtlExpired;        break;
                }
            }
            NSData* msg = buildReply(reason, nil);
            AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
            [in close];
            [out close];
            [stream close];
            return;
        }

        dispatch_queue_t connQ =
          dispatch_queue_create([[NSString stringWithFormat:@"socks.conn.%@", serverId] UTF8String],
                                DISPATCH_QUEUE_SERIAL);
        dispatch_async(socketsQ, ^{ sockets[serverId] = @{@"in":in, @"out":out, @"q":connQ}; });

        AddrSpec *bind = LocalAddrSpecFromInputStream(in);
        NSData* msg = buildReply(SocksReplySuccess, bind);
        AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@NO} mutableCopy]);

        [stream close];
        readFromProxy(serverId);
        NSLog(@"connectToProxy(): success server_id=%@", serverId);
    } else {
        NSData* msg = buildReply(SocksReplyCommandNotSupported, nil);
        AddResponse([@{@"server_id": serverId, @"data":[msg base64EncodedStringWithOptions:0], @"exit":@YES} mutableCopy]);
        [stream close];
    }
}

void HandleSocks(NSDictionary *s) {
    NSNumber *serverId = s[@"server_id"];
    BOOL exitFlag = [s[@"exit"] boolValue];
    NSData *data = (s[@"data"] && ![s[@"data"] isKindOfClass:[NSNull class]]) ?
                   [[NSData alloc] initWithBase64EncodedString:s[@"data"] options:0] : nil;
    const uint8_t *bytes = data.bytes;

    if (exitFlag) {
        closeSocket(serverId);
        return;
    }

    __block BOOL exists = NO;
    dispatch_sync(socketsQ, ^{
        exists = (sockets[serverId] != nil);
    });

    if (exists && data.length) {
        writeToProxy(serverId, data);
    } else {
        if (data.length >= 1 && bytes[0] == kSocks5Version) {
            connectToProxy(serverId, data);
        } else if (data.length >= 2 && bytes[0] == 0x00 && bytes[1] == 0x00) {
            return; // UDP not implemented
        }
    }
}
