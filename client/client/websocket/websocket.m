#import "websocket.h"

@interface WebSocketClient () <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, readwrite) BOOL isConnected;

// Inbound message buffer
@property (nonatomic, strong) dispatch_queue_t inboxQ;
@property (nonatomic, strong) NSMutableArray<NSString *> *inbox;
@property (nonatomic, strong) dispatch_semaphore_t inboxSem;
@end

@implementation WebSocketClient

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = url;
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        _session = [NSURLSession sessionWithConfiguration:config
                                                 delegate:self
                                            delegateQueue:nil];
        _isConnected = NO;

        _inboxQ = dispatch_queue_create("ws.inbox", DISPATCH_QUEUE_SERIAL);
        _inbox  = [NSMutableArray array];
        _inboxSem = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)connect {
    self.webSocketTask = [self.session webSocketTaskWithURL:self.url];
    self.webSocketTask.maximumMessageSize = 8 * 1024 * 1024;
    [self.webSocketTask resume];
    [self startReceiving];
}

- (void)disconnect {
    [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    self.isConnected = NO;
}

- (void)sendMessage:(NSString *)message {
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:message];
    [self.webSocketTask sendMessage:msg completionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"Send error: %@", error);
        }
    }];
}

- (NSString *)receiveMessage {
    dispatch_semaphore_wait(self.inboxSem, DISPATCH_TIME_FOREVER);
    __block NSString *out = nil;
    dispatch_sync(self.inboxQ, ^{
        if (self.inbox.count > 0) {
            out = self.inbox.firstObject;
            [self.inbox removeObjectAtIndex:0];
        }
    });
    return out;
}

- (void)startReceiving {
    __weak typeof(self) w = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(w) s = w; if (!s) return;

        if (error) {
            NSLog(@"WebSocket receive error: %@", error);
            s.isConnected = NO;
            return;
        }

        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSString *text = message.string ?: @"";
            dispatch_async(s.inboxQ, ^{
                [s.inbox addObject:text];
                dispatch_semaphore_signal(s.inboxSem);
            });
        } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
            // Handle binary frames if needed.
        }

        // Re-arm to receive the next message (receive is one-shot)
        [s startReceiving];
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString *)protocol {
    self.isConnected = YES;
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(NSData *)reason {
    self.isConnected = NO;
}

@end
