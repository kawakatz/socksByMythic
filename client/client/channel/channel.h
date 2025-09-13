#import <Foundation/Foundation.h>

void InitChannel(void);
void AddResponse(NSDictionary *socks);
NSArray<NSDictionary *> *DrainResponses(void);
