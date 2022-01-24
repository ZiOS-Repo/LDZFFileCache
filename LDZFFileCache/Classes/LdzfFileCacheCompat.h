//
//  LdzfFileCacheCompat.h
//  LdzfFileCache
//
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef void(^LdzfFileCacheNoParamsBlock)(void);

FOUNDATION_EXPORT NSString *const LdzfFileCacheErrorDomain;

#ifndef dispatch_queue_async_safe
#define dispatch_queue_async_safe(queue, block)\
    if (dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL) == dispatch_queue_get_label(queue)) {\
        block();\
    } else {\
        dispatch_async(queue, block);\
    }
#endif

#ifndef dispatch_main_async_safe
#define dispatch_main_async_safe(block) dispatch_queue_async_safe(dispatch_get_main_queue(), block)
#endif
