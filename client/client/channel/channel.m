#import "channel.h"

static NSMutableArray<NSDictionary *> *responses;
static dispatch_queue_t responsesQueue;
static dispatch_semaphore_t responsesReady;

void InitChannel(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    responses = [NSMutableArray array];
    responsesQueue =
        dispatch_queue_create("response.queue", DISPATCH_QUEUE_SERIAL);
    responsesReady = dispatch_semaphore_create(0);
  });
}

void AddResponse(NSDictionary *response) {
  dispatch_async(responsesQueue, ^{
    BOOL notify = responses.count == 0;
    [responses addObject:response];
    if (notify) {
      dispatch_semaphore_signal(responsesReady);
    }
  });
}

NSArray<NSDictionary *> *WaitForResponses(void) {
  dispatch_semaphore_wait(responsesReady, DISPATCH_TIME_FOREVER);
  __block NSArray<NSDictionary *> *batch;
  dispatch_sync(responsesQueue, ^{
    batch = [responses copy];
    [responses removeAllObjects];
  });
  return batch;
}
