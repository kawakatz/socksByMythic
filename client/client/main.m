#import <Foundation/Foundation.h>
#import <signal.h>
#import "websocket.h"
#import "channel.h"
#import "socks.h"

static BOOL shouldExit = NO;

void sigintHandler(int sig) {
    NSLog(@"\nReceived SIGINT, shutting down...");
    shouldExit = YES;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        signal(SIGINT, sigintHandler);

        InitChannel();
        InitSocks();

        if (argc < 2) {
            NSLog(@"usage: ./client ws://<ip>/ws");
            return 1;
        }
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
        WebSocketClient *client = [[WebSocketClient alloc] initWithURL:url];

        [client connect];

        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (!client.isConnected && [timeout timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!client.isConnected) {
            NSLog(@"Failed to connect within 5 seconds");
            return 1;
        }
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            while (!shouldExit) {
                NSString *received = [client receiveMessage]; // blocking
                if (received.length == 0) { continue; }

                NSData *data = [received dataUsingEncoding:NSUTF8StringEncoding];
                NSError *error = nil;
                NSArray *batch = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                if (error || ![batch isKindOfClass:[NSArray class]]) { continue; }

                for (id item in batch) {
                    if ([item isKindOfClass:[NSDictionary class]]) {
                        HandleSocks((NSDictionary *)item);
                    }
                }
            }
        });
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            while (!shouldExit) {
                NSArray<NSDictionary *>* responses = DrainResponses();
                if (responses.count > 0) {
                    NSError *err = nil;
                    NSData *data = [NSJSONSerialization dataWithJSONObject:responses options:0 error:&err];
                    if (data && !err) {
                        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        if (message) {
                            [client sendMessage:message];
                            NSLog(@"Sent(batch): %lu item(s), %lu bytes", (unsigned long)responses.count, (unsigned long)data.length);
                        }
                    } else {
                        NSLog(@"Batch JSON encode error: %@", err);
                    }
                }
                
                usleep(1 * 1000);
            }
        });

        NSLog(@"Press Ctrl+C to exit...");
        while (!shouldExit) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }

        [client disconnect];
    }
    return 0;
}

