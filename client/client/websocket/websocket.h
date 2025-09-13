#import <Foundation/Foundation.h>

@interface WebSocketClient : NSObject

@property (nonatomic, readonly) BOOL isConnected;

- (instancetype)initWithURL:(NSURL *)url;
- (void)connect;
- (void)disconnect;
- (void)sendMessage:(NSString *)message;
- (NSString *)receiveMessage;

@end
