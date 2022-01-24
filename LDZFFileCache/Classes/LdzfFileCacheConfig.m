//
//  LdzfFileCacheConfig.m
//  LdzfFileCache
//
//

#import "LdzfFileCacheConfig.h"

static const NSInteger kDefaultCacheMaxCacheAge = 60 * 60 * 24 * 7; // 1 week

@implementation LdzfFileCacheConfig

- (instancetype)init {
    if (self = [super init]) {
        _shouldCacheImagesInMemory = YES;
        _shouldUseWeakMemoryCache = YES;
        _diskCacheReadingOptions = 0;
        _diskCacheWritingOptions = NSDataWritingAtomic;
        _maxCacheAge = kDefaultCacheMaxCacheAge;
        _maxCacheSize = 0;
        _diskCacheExpireType = LdzfFileCacheConfigExpireTypeModificationDate;
    }
    return self;
}

@end
