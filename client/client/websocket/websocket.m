#import "websocket.h"

static const int64_t kSendTimeout = 10 * NSEC_PER_SEC;

@interface WebSocketClient () <NSURLSessionWebSocketDelegate>
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property(atomic, readwrite) BOOL isConnected;
@property(nonatomic, strong) dispatch_queue_t inboxQueue;
@property(nonatomic, strong) NSMutableArray<NSString *> *inbox;
@property(nonatomic, strong) dispatch_semaphore_t inboxReady;
@property(nonatomic) BOOL closed;
@end

@implementation WebSocketClient

- (instancetype)initWithURL:(NSURL *)url {
  self = [super init];
  if (self) {
    _url = url;
    _inboxQueue = dispatch_queue_create("ws.inbox", DISPATCH_QUEUE_SERIAL);
    _inbox = [NSMutableArray array];
    _inboxReady = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    _session = [NSURLSession sessionWithConfiguration:configuration
                                             delegate:self
                                        delegateQueue:nil];
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
  [self.webSocketTask
      cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                   reason:nil];
  [self finish];
}

- (BOOL)sendMessage:(NSString *)message {
  if (!self.isConnected) {
    return NO;
  }

  dispatch_semaphore_t completed = dispatch_semaphore_create(0);
  __block NSError *sendError;
  NSURLSessionWebSocketMessage *webSocketMessage =
      [[NSURLSessionWebSocketMessage alloc] initWithString:message];
  [self.webSocketTask sendMessage:webSocketMessage
                completionHandler:^(NSError *error) {
                  sendError = error;
                  dispatch_semaphore_signal(completed);
                }];

  if (dispatch_semaphore_wait(
          completed, dispatch_time(DISPATCH_TIME_NOW, kSendTimeout)) != 0) {
    NSLog(@"WebSocket send timed out");
    [self finish];
    return NO;
  }
  if (sendError) {
    NSLog(@"WebSocket send error: %@", sendError);
    [self finish];
    return NO;
  }
  return YES;
}

- (nullable NSString *)receiveMessage {
  dispatch_semaphore_wait(self.inboxReady, DISPATCH_TIME_FOREVER);
  __block NSString *message;
  dispatch_sync(self.inboxQueue, ^{
    if (self.inbox.count > 0) {
      message = self.inbox.firstObject;
      [self.inbox removeObjectAtIndex:0];
    }
  });
  return message;
}

- (void)startReceiving {
  __weak typeof(self) weakSelf = self;
  [self.webSocketTask
      receiveMessageWithCompletionHandler:^(
          NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
          return;
        }
        if (error) {
          NSLog(@"WebSocket receive error: %@", error);
          [self finish];
          return;
        }
        if (message.type != NSURLSessionWebSocketMessageTypeString) {
          NSLog(@"Ignoring non-text WebSocket message");
          [self startReceiving];
          return;
        }

        NSString *text = message.string ?: @"";
        dispatch_async(self.inboxQueue, ^{
          if (!self.closed) {
            [self.inbox addObject:text];
            dispatch_semaphore_signal(self.inboxReady);
          }
        });
        [self startReceiving];
      }];
}

- (void)finish {
  self.isConnected = NO;
  dispatch_async(self.inboxQueue, ^{
    if (!self.closed) {
      self.closed = YES;
      dispatch_semaphore_signal(self.inboxReady);
    }
  });
  [self.session invalidateAndCancel];
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
  [self finish];
}

@end
