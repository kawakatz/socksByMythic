#import <Foundation/Foundation.h>
#import <signal.h>
#import <stdatomic.h>

#import "channel.h"
#import "socks.h"
#import "websocket.h"

static volatile sig_atomic_t interrupted;
static atomic_bool exitRequested = ATOMIC_VAR_INIT(false);

static void SignalHandler(int signalNumber) {
  (void)signalNumber;
  interrupted = 1;
}

static BOOL ShouldExit(void) {
  return interrupted != 0 || atomic_load(&exitRequested);
}

static void RequestExit(void) { atomic_store(&exitRequested, true); }

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2) {
      NSLog(@"Usage: client ws://<host>/ws");
      return 1;
    }

    NSString *argument = [NSString stringWithUTF8String:argv[1]];
    NSURL *url = argument ? [NSURL URLWithString:argument] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (!url.host.length ||
        !([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"])) {
      NSLog(@"Invalid WebSocket URL: %@", argument ?: @"(invalid UTF-8)");
      return 1;
    }

    signal(SIGINT, SignalHandler);
    signal(SIGTERM, SignalHandler);
    InitChannel();
    InitSocks();

    WebSocketClient *client = [[WebSocketClient alloc] initWithURL:url];
    [client connect];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!client.isConnected && [deadline timeIntervalSinceNow] > 0) {
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!client.isConnected) {
      NSLog(@"Failed to connect within 5 seconds");
      [client disconnect];
      return 1;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      while (!ShouldExit()) {
        @autoreleasepool {
          NSString *received = [client receiveMessage];
          if (!received) {
            RequestExit();
            break;
          }
          NSData *data = [received dataUsingEncoding:NSUTF8StringEncoding];
          NSError *error = nil;
          id value = data ? [NSJSONSerialization JSONObjectWithData:data
                                                            options:0
                                                              error:&error]
                          : nil;
          if (![value isKindOfClass:[NSArray class]]) {
            NSLog(@"Invalid WebSocket payload: %@", error);
            RequestExit();
            break;
          }
          for (id item in (NSArray *)value) {
            if ([item isKindOfClass:[NSDictionary class]]) {
              HandleSocks(item);
            }
          }
        }
      }
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      while (!ShouldExit()) {
        @autoreleasepool {
          NSArray<NSDictionary *> *responses = WaitForResponses();
          NSError *error = nil;
          NSData *data = [NSJSONSerialization dataWithJSONObject:responses
                                                         options:0
                                                           error:&error];
          NSString *message =
              data ? [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding]
                   : nil;
          if (!message) {
            NSLog(@"JSON encode error: %@", error);
            RequestExit();
            break;
          }
          if (![client sendMessage:message]) {
            RequestExit();
            break;
          }
          NSLog(@"Sent(batch): %lu item(s), %lu bytes",
                (unsigned long)responses.count, (unsigned long)data.length);
        }
      }
    });

    NSLog(@"Press Ctrl+C to exit");
    while (!ShouldExit() && client.isConnected) {
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    [client disconnect];
  }
  return 0;
}
