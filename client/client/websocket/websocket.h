#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WebSocketClient : NSObject

@property(atomic, readonly) BOOL isConnected;

- (instancetype)initWithURL:(NSURL *)url;
- (void)connect;
- (void)disconnect;
- (BOOL)sendMessage:(NSString *)message;
- (nullable NSString *)receiveMessage;

@end

NS_ASSUME_NONNULL_END
