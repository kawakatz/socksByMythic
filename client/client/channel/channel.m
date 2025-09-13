#include "channel.h"

static NSMutableArray<NSDictionary *> *responses;
static dispatch_queue_t responsesQueue;

void InitChannel(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        responses = [NSMutableArray array];
        responsesQueue = dispatch_queue_create("response.queue", DISPATCH_QUEUE_SERIAL);
    });
}

void AddResponse(NSDictionary *socks) {
    dispatch_async(responsesQueue, ^{
        [responses addObject:socks];
    });
}

NSArray<NSDictionary *> *DrainResponses(void) {
    __block NSArray *copied = nil;
    dispatch_sync(responsesQueue, ^{
        copied = [responses copy];
        [responses removeAllObjects];
    });
    return copied;
}
