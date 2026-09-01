#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void InitChannel(void);
void AddResponse(NSDictionary *socks);
NSArray<NSDictionary *> *WaitForResponses(void);

NS_ASSUME_NONNULL_END
