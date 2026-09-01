// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2022, its-a-feature
// Copyright (c) 2025, kawakatz
// Derived from Poseidon and go-socks5; see NOTICE.md.

#import "socks.h"
#import "channel.h"

#import <arpa/inet.h>
#import <math.h>
#import <sys/socket.h>

static NSMutableDictionary<NSNumber *, NSDictionary *> *sockets;
static dispatch_queue_t socketsQueue;

@interface AddrSpec : NSObject
@property(nonatomic, copy, nullable) NSString *FQDN;
@property(nonatomic, copy, nullable) NSString *IP;
@property(nonatomic) uint16_t Port;
@end
@implementation AddrSpec
@end

static const uint8_t kSocks5Version = 0x05;
static const uint8_t kATYPIPv4 = 0x01;
static const uint8_t kATYPFQDN = 0x03;
static const uint8_t kATYPIPv6 = 0x04;

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
  socketsQueue = dispatch_queue_create("socks.table", DISPATCH_QUEUE_SERIAL);
  sockets = [NSMutableDictionary dictionary];
}

// Always return VER|REP|RSV|ATYP|BND.ADDR|BND.PORT
static NSData *buildReply(uint8_t rep, AddrSpec *_Nullable addr) {
  uint8_t addrType = kATYPIPv4;
  NSData *addrBody = nil;
  uint16_t addrPort = 0;

  if (!addr) {
    uint8_t zero[4] = {0, 0, 0, 0};
    addrBody = [NSData dataWithBytes:zero length:4];
  } else if (addr.FQDN.length > 0) {
    NSData *fqdn = [addr.FQDN dataUsingEncoding:NSUTF8StringEncoding];
    if (!fqdn || fqdn.length > 255) {
      uint8_t zero[4] = {0, 0, 0, 0};
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
    struct in_addr v4;
    memset(&v4, 0, sizeof v4);
    struct in6_addr v6;
    memset(&v6, 0, sizeof v6);
    if (inet_pton(AF_INET, addr.IP.UTF8String, &v4) == 1) {
      addrType = kATYPIPv4;
      addrBody = [NSData dataWithBytes:&v4 length:4];
      addrPort = addr.Port;
    } else if (inet_pton(AF_INET6, addr.IP.UTF8String, &v6) == 1) {
      addrType = kATYPIPv6;
      addrBody = [NSData dataWithBytes:&v6 length:16];
      addrPort = addr.Port;
    } else {
      uint8_t zero[4] = {0, 0, 0, 0};
      addrBody = [NSData dataWithBytes:zero length:4];
    }
  } else {
    uint8_t zero[4] = {0, 0, 0, 0};
    addrBody = [NSData dataWithBytes:zero length:4];
  }

  NSMutableData *msg = [NSMutableData dataWithCapacity:6 + addrBody.length];
  const uint8_t header[4] = {kSocks5Version, rep, 0x00, addrType};
  [msg appendBytes:header length:sizeof header];
  [msg appendData:addrBody];
  uint8_t p[2] = {(uint8_t)(addrPort >> 8), (uint8_t)(addrPort & 0xFF)};
  [msg appendBytes:p length:2];
  return msg;
}

static AddrSpec *_Nullable LocalAddrSpecFromInputStream(NSInputStream *in) {
  CFDataRef d = CFReadStreamCopyProperty((__bridge CFReadStreamRef)in,
                                         kCFStreamPropertySocketNativeHandle);
  if (!d)
    return nil;
  CFSocketNativeHandle fd = -1;
  CFDataGetBytes(d, CFRangeMake(0, sizeof(fd)), (UInt8 *)&fd);
  CFRelease(d);
  if (fd < 0)
    return nil;

  struct sockaddr_storage ss;
  socklen_t len = sizeof(ss);
  if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0)
    return nil;

  char host[INET6_ADDRSTRLEN] = {0};
  uint16_t port = 0;
  if (ss.ss_family == AF_INET) {
    struct sockaddr_in *sin = (struct sockaddr_in *)&ss;
    inet_ntop(AF_INET, &sin->sin_addr, host, sizeof(host));
    port = ntohs(sin->sin_port);
  } else if (ss.ss_family == AF_INET6) {
    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&ss;
    inet_ntop(AF_INET6, &sin6->sin6_addr, host, sizeof(host));
    port = ntohs(sin6->sin6_port);
  } else {
    return nil;
  }

  AddrSpec *a = [AddrSpec new];
  a.IP = [NSString stringWithUTF8String:host];
  a.Port = port;
  return a;
}

static NSString *_Nullable HostFromAddrSpec(AddrSpec *addr) {
  if (addr.Port == 0)
    return nil;
  if (addr.FQDN.length > 0)
    return addr.FQDN;
  if (addr.IP.length > 0)
    return addr.IP;
  return nil;
}

static BOOL closeSocket(NSNumber *serverId) {
  __block NSDictionary *pair;
  dispatch_sync(socketsQueue, ^{
    pair = sockets[serverId];
    [sockets removeObjectForKey:serverId];
  });
  if (!pair)
    return NO;

  NSInputStream *in = pair[@"in"];
  NSOutputStream *out = pair[@"out"];

  if (in) {
    CFReadStreamSetProperty((__bridge CFReadStreamRef)in,
                            kCFStreamPropertyShouldCloseNativeSocket,
                            kCFBooleanTrue);
  }
  if (out) {
    CFWriteStreamSetProperty((__bridge CFWriteStreamRef)out,
                             kCFStreamPropertyShouldCloseNativeSocket,
                             kCFBooleanTrue);
  }

  in.delegate = nil;
  out.delegate = nil;
  [in close];
  [out close];
  return YES;
}

static void addResponse(NSNumber *serverId, NSData *_Nullable data,
                        BOOL exitFlag) {
  AddResponse(@{
    @"server_id" : serverId,
    @"data" : data ? [data base64EncodedStringWithOptions:0] : @"",
    @"exit" : @(exitFlag),
  });
}

static void closeWithResponse(NSNumber *serverId) {
  if (closeSocket(serverId)) {
    addResponse(serverId, nil, YES);
  }
}

static void writeToProxy(NSNumber *serverId, NSData *data) {
  __block NSDictionary *pair;
  dispatch_sync(socketsQueue, ^{
    pair = sockets[serverId];
  });
  NSOutputStream *out = pair[@"out"];
  dispatch_queue_t q = pair[@"q"];
  if (!out || !q) {
    NSLog(@"writeToProxy(): socket not found server_id=%@", serverId);
    return;
  }

  dispatch_async(q, ^{
    const uint8_t *bytes = data.bytes;
    NSUInteger total = data.length, offset = 0;

    while (offset < total) {
      if (out.streamStatus == NSStreamStatusError ||
          out.streamStatus == NSStreamStatusClosed) {
        NSLog(@"writeToProxy(): stream error/closed server_id=%@", serverId);
        closeWithResponse(serverId);
        return;
      }
      NSInteger n = [out write:bytes + offset maxLength:(total - offset)];
      if (n > 0) {
        offset += (NSUInteger)n;
      } else if (n == 0) {
        usleep(10 * 1000);
      } else {
        NSLog(@"writeToProxy(): write error server_id=%@", serverId);
        closeWithResponse(serverId);
        return;
      }
    }
  });
}

static void readFromProxy(NSNumber *serverId) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    __block NSInputStream *in = nil;
    dispatch_sync(socketsQueue, ^{
      NSDictionary *pair = sockets[serverId];
      in = (NSInputStream *)pair[@"in"];
    });
    if (!in) {
      NSLog(@"readFromProxy(): socket not found");
      return;
    }

    uint8_t buf[4096];
    for (;;) {
      NSInteger n = [in read:buf maxLength:sizeof(buf)];
      if (n > 0) {
        addResponse(serverId, [NSData dataWithBytes:buf length:(NSUInteger)n],
                    NO);
      } else {
        closeWithResponse(serverId);
        return;
      }
    }
  });
}

static BOOL waitForOpen(NSInputStream *in, NSOutputStream *out,
                        NSTimeInterval timeout) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  for (;;) {
    NSStreamStatus si = in.streamStatus, so = out.streamStatus;
    if ((si == NSStreamStatusOpen || si == NSStreamStatusReading) &&
        (so == NSStreamStatusOpen || so == NSStreamStatusWriting)) {
      return YES;
    }
    if (si == NSStreamStatusError || so == NSStreamStatusError)
      return NO;
    if ([deadline timeIntervalSinceNow] <= 0)
      return NO;
    usleep(20 * 1000);
  }
}

static void connectToProxy(NSNumber *serverId, NSData *data) {
  const uint8_t *bytes = data.bytes;
  if (data.length < 4 || bytes[0] != kSocks5Version) {
    addResponse(serverId, nil, YES);
    return;
  }
  if (bytes[1] != 0x01 || bytes[2] != 0x00) {
    addResponse(serverId, buildReply(SocksReplyCommandNotSupported, nil), YES);
    return;
  }

  AddrSpec *destination = [AddrSpec new];
  NSUInteger offset = 4;
  switch (bytes[3]) {
  case kATYPIPv4: {
    if (data.length < offset + 4 + 2) {
      addResponse(serverId, buildReply(SocksReplyServerFailure, nil), YES);
      return;
    }
    char address[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET, bytes + offset, address, sizeof(address))) {
      addResponse(serverId, buildReply(SocksReplyAddrTypeNotSupported, nil),
                  YES);
      return;
    }
    destination.IP = [NSString stringWithUTF8String:address];
    offset += 4;
    break;
  }
  case kATYPFQDN: {
    if (data.length < offset + 1) {
      addResponse(serverId, buildReply(SocksReplyServerFailure, nil), YES);
      return;
    }
    NSUInteger length = bytes[offset++];
    if (length == 0 || data.length < offset + length + 2) {
      addResponse(serverId, buildReply(SocksReplyAddrTypeNotSupported, nil),
                  YES);
      return;
    }
    destination.FQDN = [[NSString alloc] initWithBytes:bytes + offset
                                                length:length
                                              encoding:NSUTF8StringEncoding];
    if (!destination.FQDN) {
      addResponse(serverId, buildReply(SocksReplyAddrTypeNotSupported, nil),
                  YES);
      return;
    }
    offset += length;
    break;
  }
  case kATYPIPv6: {
    if (data.length < offset + 16 + 2) {
      addResponse(serverId, buildReply(SocksReplyServerFailure, nil), YES);
      return;
    }
    char address[INET6_ADDRSTRLEN];
    if (!inet_ntop(AF_INET6, bytes + offset, address, sizeof(address))) {
      addResponse(serverId, buildReply(SocksReplyAddrTypeNotSupported, nil),
                  YES);
      return;
    }
    destination.IP = [NSString stringWithUTF8String:address];
    offset += 16;
    break;
  }
  default:
    addResponse(serverId, buildReply(SocksReplyAddrTypeNotSupported, nil), YES);
    return;
  }

  destination.Port = (uint16_t)((bytes[offset] << 8) | bytes[offset + 1]);
  offset += 2;
  NSString *host = HostFromAddrSpec(destination);
  if (!host) {
    addResponse(serverId, buildReply(SocksReplyAddrTypeNotSupported, nil), YES);
    return;
  }

  CFReadStreamRef readStream = NULL;
  CFWriteStreamRef writeStream = NULL;
  CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host,
                                     destination.Port, &readStream,
                                     &writeStream);
  NSInputStream *in = CFBridgingRelease(readStream);
  NSOutputStream *out = CFBridgingRelease(writeStream);
  if (!in || !out) {
    addResponse(serverId, buildReply(SocksReplyServerFailure, nil), YES);
    return;
  }

  [in open];
  [out open];
  if (!waitForOpen(in, out, 5.0)) {
    NSError *streamError = in.streamError ?: out.streamError;
    uint8_t reply = SocksReplyServerFailure;
    if ([streamError.domain isEqualToString:NSPOSIXErrorDomain]) {
      switch (streamError.code) {
      case ECONNREFUSED:
        reply = SocksReplyConnectionRefused;
        break;
      case ENETUNREACH:
        reply = SocksReplyNetworkUnreachable;
        break;
      case EHOSTUNREACH:
        reply = SocksReplyHostUnreachable;
        break;
      case ETIMEDOUT:
        reply = SocksReplyTtlExpired;
        break;
      }
    }
    addResponse(serverId, buildReply(reply, nil), YES);
    [in close];
    [out close];
    return;
  }

  dispatch_queue_t writeQueue = dispatch_queue_create(
      [[NSString stringWithFormat:@"socks.conn.%@", serverId] UTF8String],
      DISPATCH_QUEUE_SERIAL);
  dispatch_sync(socketsQueue, ^{
    sockets[serverId] = @{@"in" : in, @"out" : out, @"q" : writeQueue};
  });

  addResponse(serverId,
              buildReply(SocksReplySuccess, LocalAddrSpecFromInputStream(in)),
              NO);
  if (data.length > offset) {
    writeToProxy(
        serverId,
        [data subdataWithRange:NSMakeRange(offset, data.length - offset)]);
  }
  readFromProxy(serverId);
}

void HandleSocks(NSDictionary *s) {
  id rawServerId = s[@"server_id"];
  id rawData = s[@"data"];
  id rawExit = s[@"exit"];
  if (![rawServerId isKindOfClass:[NSNumber class]] ||
      CFGetTypeID((__bridge CFTypeRef)rawServerId) == CFBooleanGetTypeID() ||
      ![rawExit isKindOfClass:[NSNumber class]] ||
      CFGetTypeID((__bridge CFTypeRef)rawExit) != CFBooleanGetTypeID() ||
      !([rawData isKindOfClass:[NSString class]] ||
        [rawData isKindOfClass:[NSNull class]])) {
    NSLog(@"Ignoring malformed proxy message");
    return;
  }

  double numericId = [rawServerId doubleValue];
  if (!isfinite(numericId) || numericId < 1 || numericId > UINT32_MAX ||
      trunc(numericId) != numericId) {
    NSLog(@"Ignoring invalid server_id: %@", rawServerId);
    return;
  }
  NSNumber *serverId = @((uint32_t)numericId);
  BOOL exitFlag = [rawExit boolValue];
  NSData *data = [rawData isKindOfClass:[NSString class]]
                     ? [[NSData alloc] initWithBase64EncodedString:rawData
                                                           options:0]
                     : nil;
  if ([rawData isKindOfClass:[NSString class]] && !data) {
    addResponse(serverId, nil, YES);
    closeSocket(serverId);
    return;
  }
  const uint8_t *bytes = data.bytes;

  if (exitFlag) {
    closeSocket(serverId);
    return;
  }

  __block BOOL exists = NO;
  dispatch_sync(socketsQueue, ^{
    exists = (sockets[serverId] != nil);
  });

  if (exists && data.length) {
    writeToProxy(serverId, data);
  } else if (!exists && data.length >= 1 && bytes[0] == kSocks5Version) {
    connectToProxy(serverId, data);
  } else {
    addResponse(serverId, nil, YES);
    closeSocket(serverId);
  }
}
