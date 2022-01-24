//
//  LdzfFileCache.m
//  LdzfFileCache
//
#import <CommonCrypto/CommonDigest.h>
#import "LdzfFileCache.h"
#import "LdzfFileCacheConfig.h"

#define SD_MAX_FILE_EXTENSION_LENGTH (NAME_MAX - CC_MD5_DIGEST_LENGTH * 2 - 1)
#define LOCK(lock) dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

// A memory cache which auto purge the cache on memory warning and support weak cache.
@interface BSIMemoryCache <KeyType, ObjectType> : NSCache <KeyType, ObjectType>

@end

// Private
@interface BSIMemoryCache <KeyType, ObjectType> ()
@property (nonatomic, strong, nonnull) LdzfFileCacheConfig *config;
@property (nonatomic, strong, nonnull) NSMapTable<KeyType, ObjectType> *weakCache; // strong-weak cache
@property (nonatomic, strong, nonnull) dispatch_semaphore_t weakCacheLock; // a lock to keep the access to `weakCache` thread-safe

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithConfig:(nonnull LdzfFileCacheConfig *)config;

@end

@implementation BSIMemoryCache
- (void)dealloc {
    //移除内存警告通知
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

- (instancetype)initWithConfig:(LdzfFileCacheConfig *)config {
    self = [super init];
    if (self) {
        // 使用存储二级缓存的强弱映射表。 按照NSCache不复制密钥的文档
        // 当内存警告，缓存被清除时，这很有用。 但是，图像实例可以由其他实例保留，例如imageViews和alive。
        // 在这种情况下，我们可以同步弱缓存，而不需要从磁盘缓存加载
        self.weakCache = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory capacity:0];
        self.weakCacheLock = dispatch_semaphore_create(1);
        self.config = config;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    //只删除缓存，但保持弱缓存
    [super removeAllObjects];
}

// `setObject:forKey:` 只需调用0即可，覆盖这就足够了
- (void)setObject:(id)obj forKey:(id)key cost:(NSUInteger)g {
    //调用系统的NSCache方法
    [super setObject:obj forKey:key cost:g];
    //如果缓存配置不使用弱内存缓存，返回
    if (!self.config.shouldUseWeakMemoryCache) {
        return;
    }
    if (key && obj) {
        //若果key和obj存在，存储弱缓存
        LOCK(self.weakCacheLock);
        [self.weakCache setObject:obj forKey:key];
        UNLOCK(self.weakCacheLock);
    }
}

//通过key获取object
- (id)objectForKey:(id)key {
    id obj = [super objectForKey:key];
    if (!self.config.shouldUseWeakMemoryCache) {
        return obj;
    }
    if (key && !obj) {
        // 若果key存在，obj不存在，存储弱缓存
        LOCK(self.weakCacheLock);
        obj = [self.weakCache objectForKey:key];
        UNLOCK(self.weakCacheLock);
        if (obj) {
            //同步缓存
            [super setObject:obj forKey:key];
        }
    }
    return obj;
}

//根据key移除对象
- (void)removeObjectForKey:(id)key {
    [super removeObjectForKey:key];
    //如果缓存配置不使用弱内存缓存，返回
    if (!self.config.shouldUseWeakMemoryCache) {
        return;
    }
    if (key) {
        // 如果key存在，移除缓存
        LOCK(self.weakCacheLock);
        [self.weakCache removeObjectForKey:key];
        UNLOCK(self.weakCacheLock);
    }
}
//移除所有对象
- (void)removeAllObjects {
    [super removeAllObjects];
    //如果缓存配置不使用弱内存缓存，返回
    if (!self.config.shouldUseWeakMemoryCache) {
        return;
    }
    // 手动删除也应该删除弱缓存
    LOCK(self.weakCacheLock);
    [self.weakCache removeAllObjects];
    UNLOCK(self.weakCacheLock);
}
@end





@interface LdzfFileCache ()

#pragma mark - 属性
//内存缓存
@property (strong, nonatomic, nonnull) BSIMemoryCache *memCache;
//磁盘缓存路径
@property (strong, nonatomic, nonnull) NSString *diskCachePath;
//自定义路径
@property (strong, nonatomic, nullable) NSMutableArray<NSString *> *customPaths;
@property (strong, nonatomic, nullable) dispatch_queue_t ioQueue;
//文件管理器
@property (strong, nonatomic, nonnull) NSFileManager *fileManager;

@end


@implementation LdzfFileCache

#pragma mark - Singleton, init, dealloc

+ (nonnull instancetype)sharedCache {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (instancetype)init {
    return [self initWithNamespace:@"LdzfFileCache"];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns {
    //获取磁盘缓存路径，默认的是：~/LdzfFileCache （ns为LdzfFileCache，拼接到缓存路径的最后面）
    NSString *path = [self makeDiskCachePath:ns];
    return [self initWithNamespace:ns diskCacheDirectory:path];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory {
    if ((self = [super init])) {
        NSString *fullNamespace = [@"com.hackemist.LdzfFileCache." stringByAppendingString:ns];
                
        // 创建IO串行队列
        _ioQueue = dispatch_queue_create("com.hackemist.LdzfFileCache", DISPATCH_QUEUE_SERIAL);
        
        //初始化缓存配置
        _config = [[LdzfFileCacheConfig alloc] init];
        
        // 初始化内存缓存
        _memCache = [[BSIMemoryCache alloc] initWithConfig:_config];
        _memCache.name = fullNamespace;

        // 初始化磁盘缓存
        if (directory != nil) {
            //如果路径不为nil，在路径的结尾拼接fullNamespace
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
           //如果路径为nil，获取路径
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }
        NSLog(@"LdzfFileCachePath %@",_diskCachePath);
        dispatch_sync(_ioQueue, ^{
            //初始化文件管理器
            self.fileManager = [NSFileManager new];
        });

    
        //添加删除通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deleteOldFiles)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundDeleteOldFiles)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];

    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 缓存路径
- (void)addReadOnlyCachePath:(nonnull NSString *)path {
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }

    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}

- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path {
    NSString *filename = [self cachedFileNameForKey:key];
    return [path stringByAppendingPathComponent:filename];
}

- (nullable NSString *)defaultCachePathForKey:(nullable NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}

- (nullable NSString *)cachedFileNameForKey:(nullable NSString *)key {
    const char *str = key.UTF8String;
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSURL *keyURL = [NSURL URLWithString:key];
    NSString *ext = keyURL ? keyURL.pathExtension : key.pathExtension;
    // File system has file name length limit, we need to check if ext is too long, we don't add it to the filename
    if (ext.length > SD_MAX_FILE_EXTENSION_LENGTH) {
        ext = nil;
    }
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], ext.length == 0 ? @"" : [NSString stringWithFormat:@".%@", ext]];
    return filename;
}

- (nullable NSString *)makeDiskCachePath:(nonnull NSString*)fullNamespace {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}

#pragma mark - 存储操作
- (void)storeBsiDataToDisk:(nullable NSData *)bsiData
                    forKey:(nullable NSString *)key
                completion:(nullable LdzfFileCacheNoParamsBlock)completionBlock;
{
    [self storeBsiDataToDisk:bsiData forKey:key toDisk:YES completion:completionBlock];
}


- (void)storeBsiDataToDisk:(nullable NSData *)bsiData
                    forKey:(nullable NSString *)key
                    toDisk:(BOOL)toDisk
                completion:(nullable LdzfFileCacheNoParamsBlock)completionBlock {
    //若数据或者key不存在，则不存储，执行回调，返回
    if (!bsiData || !key) {
        if (completionBlock) {
            completionBlock();
        }
        return;
    }
    // 如果启用了内存缓存
    if (self.config.shouldCacheImagesInMemory) {
        [self.memCache setObject:bsiData forKey:key];
    }
    
    if (toDisk) {
        //异步执行缓存操作
        dispatch_async(self.ioQueue, ^{
            @autoreleasepool { //自动释放池（里面创建了很多临时变量，当@autoreleasepool结束时，里面的内存就会回收）
                [self _storeBsiDataToDisk:bsiData forKey:key];
            }
            
            if (completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock();
                });
            }
        });
    } else {
        if (completionBlock) {
            completionBlock();
        }
    }
}

// Make sure to call form io queue by caller
- (void)_storeBsiDataToDisk:(nullable NSData *)bsiData forKey:(nullable NSString *)key {
    if (!bsiData || !key) {
        return;
    }
    
    if (![self.fileManager fileExistsAtPath:_diskCachePath]) {
        [self.fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    
    // get cache Path for image key
    NSString *cachePathForKey = [self defaultCachePathForKey:key];
    // transform to NSUrl
    NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];
    
    [bsiData writeToURL:fileURL options:self.config.diskCacheWritingOptions error:nil];
}

#pragma mark - 查询和检索操作
- (void)diskBsiDataExistsWithKey:(nullable NSString *)key completion:(nullable LdzfFileCacheCheckCacheCompletionBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        BOOL exists = [self _diskBsiDataExistsWithKey:key];
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}

- (BOOL)diskBsiDataExistsWithKey:(nullable NSString *)key {
    if (!key) {
        return NO;
    }
    __block BOOL exists = NO;
    dispatch_sync(self.ioQueue, ^{
        exists = [self _diskBsiDataExistsWithKey:key];
    });
    
    return exists;
}

// Make sure to call form io queue by caller
- (BOOL)_diskBsiDataExistsWithKey:(nullable NSString *)key {
    if (!key) {
        return NO;
    }
    BOOL exists = [self.fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];
    
    // fallback because of https://github.com/SDWebImage/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    if (!exists) {
        exists = [self.fileManager fileExistsAtPath:[self defaultCachePathForKey:key].stringByDeletingPathExtension];
    }
    
    return exists;
}

- (nullable NSData *)diskBsiDataForKey:(nullable NSString *)key {
    if (!key) {
        return nil;
    }
    __block NSData *data = nil;
    dispatch_sync(self.ioQueue, ^{
        data = [self diskBsiDataBySearchingAllPathsForKey:key];
    });
    
    return data;
}

- (nullable NSData *)bsiDataFromMemoryCacheForKey:(nullable NSString *)key {
    return [self.memCache objectForKey:key];
}

- (nullable NSData *)bsiDataFromDiskCacheForKey:(nullable NSString *)key {
    NSData *data = [self diskBsiDataForKey:key];
    if (data && self.config.shouldCacheImagesInMemory) {
        [self.memCache setObject:data forKey:key];
    }

    return data;
}

- (nullable NSData *)bsiDataFromCacheForKey:(nullable NSString *)key {
    // First check the in-memory cache...
    NSData *data = [self bsiDataFromMemoryCacheForKey:key];
    if (data) {
        return data;
    }
    
    // Second check the disk cache...
    data = [self bsiDataFromDiskCacheForKey:key];
    return data;
}

- (nullable NSData *)diskBsiDataBySearchingAllPathsForKey:(nullable NSString *)key {
    NSString *defaultPath = [self defaultCachePathForKey:key];
    NSData *data = [NSData dataWithContentsOfFile:defaultPath options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }

    // fallback because of https://github.com/SDWebImage/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    data = [NSData dataWithContentsOfFile:defaultPath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }

    NSArray<NSString *> *customPaths = [self.customPaths copy];
    for (NSString *path in customPaths) {
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *data = [NSData dataWithContentsOfFile:filePath options:self.config.diskCacheReadingOptions error:nil];
        if (data) {
            return data;
        }

        // fallback because of https://github.com/SDWebImage/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        data = [NSData dataWithContentsOfFile:filePath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
        if (data) {
            return data;
        }
    }

    return nil;
}

- (NSOperation *)queryCacheOperationForKey:(NSString *)key done:(LdzfFileCacheQueryCompletedBlock)doneBlock {
    return [self queryCacheOperationForKey:key options:0 done:doneBlock];
}

- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key options:(LdzfFileCacheOptions)options done:(nullable LdzfFileCacheQueryCompletedBlock)doneBlock {
    if (!key) {
        if (doneBlock) {
            doneBlock(nil, LdzfFileCacheTypeNone);
        }
        return nil;
    }
    
    // First check the in-memory cache...
    NSData *data = [self bsiDataFromMemoryCacheForKey:key];
    BOOL shouldQueryMemoryOnly = (data && !(options & LdzfFileCacheCacheQueryDataWhenInMemory));
    if (shouldQueryMemoryOnly) {
        if (doneBlock) {
            doneBlock(data, LdzfFileCacheTypeMemory);
        }
        return nil;
    }
    
    NSOperation *operation = [NSOperation new];
    void(^queryDiskBlock)(void) =  ^{
        if (operation.isCancelled) {
            // do not call the completion if cancelled
            return;
        }
        
        @autoreleasepool {
            NSData *diskData = [self diskBsiDataBySearchingAllPathsForKey:key];
            LdzfFileCacheType cacheType = LdzfFileCacheTypeDisk;
            if (diskData && self.config.shouldCacheImagesInMemory) {
                [self.memCache setObject:diskData forKey:key];
            }
            
            if (doneBlock) {
                if (options & LdzfFileCacheCacheQueryDiskSync) {
                    doneBlock(diskData, cacheType);
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        doneBlock(diskData, cacheType);
                    });
                }
            }
        }
    };
    
    if (options & LdzfFileCacheCacheQueryDiskSync) {
        queryDiskBlock();
    } else {
        dispatch_async(self.ioQueue, queryDiskBlock);
    }
    
    return operation;
}

#pragma mark - 移除操作

- (void)removeBsiDataForKey:(nullable NSString *)key withCompletion:(nullable LdzfFileCacheNoParamsBlock)completion {
    [self removeBsiDataForKey:key fromDisk:YES withCompletion:completion];
}

- (void)removeBsiDataForKey:(nullable NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(nullable LdzfFileCacheNoParamsBlock)completion {
    if (key == nil) {
        return;
    }

    if (self.config.shouldCacheImagesInMemory) {
        [self.memCache removeObjectForKey:key];
    }

    if (fromDisk) {
        dispatch_async(self.ioQueue, ^{
            [self.fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];
            
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
    } else if (completion){
        completion();
    }
    
}

# pragma mark - 缓存清理操作
- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

#pragma mark - Cache clean Ops

- (void)clearMemory {
    [self.memCache removeAllObjects];
}

- (void)clearDiskOnCompletion:(nullable LdzfFileCacheNoParamsBlock)completion {
    dispatch_async(self.ioQueue, ^{
        [self.fileManager removeItemAtPath:self.diskCachePath error:nil];
        [self.fileManager createDirectoryAtPath:self.diskCachePath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

- (void)deleteOldFiles {
    [self deleteOldFilesWithCompletionBlock:nil];
}

//异步从磁盘中删除所有过期的缓存图片
- (void)deleteOldFilesWithCompletionBlock:(nullable LdzfFileCacheNoParamsBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

        // Compute content date key to be used for tests
        NSURLResourceKey cacheContentDateKey = NSURLContentModificationDateKey;
        switch (self.config.diskCacheExpireType) {
            case LdzfFileCacheConfigExpireTypeAccessDate:
                cacheContentDateKey = NSURLContentAccessDateKey;
                break;

            case LdzfFileCacheConfigExpireTypeModificationDate:
                cacheContentDateKey = NSURLContentModificationDateKey;
                break;

            default:
                break;
        }
        
        //记录遍历需要预先获取文件的哪些属性
        NSArray<NSString *> *resourceKeys = @[NSURLIsDirectoryKey, cacheContentDateKey, NSURLTotalFileAllocatedSizeKey];

               
        // diskCacheURL 和 resourceKeys 这两个变量主要是为了下面生成NSDirectoryEnumerator准备的
        //此枚举器为我们的缓存文件预取有用的属性。
        /**
          * 递归地遍历diskCachePath这个文件夹中的所有目录，此处不是直接使用diskCachePath，而是使用其生成的NSURL
          * 此处使用includingPropertiesForKeys:resourceKeys，这样每个file的resourceKeys对应的属性也会在遍历时预先获取到
          * NSDirectoryEnumerationSkipsHiddenFiles表示不遍历隐藏文件
          */
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:resourceKeys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        /**
          * 获取文件的过期时间，SDWebImage中默认是一个星期
          * expirationDate为过期时间，例如：现在时间是2018/10/16/00:00:00，当前时间减去1个星期，得到
          * 2018/10/09/00:00:00，这个时间为函数中的expirationDate
          * 用这个expirationDate和最后一次修改时间modificationDate比较看谁更晚就行
          */
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.config.maxCacheAge];
        //用来存储对应文件的一些属性，比如文件所需磁盘空间
        NSMutableDictionary<NSURL *, NSDictionary<NSString *, id> *> *cacheFiles = [NSMutableDictionary dictionary];
        //记录党建已经使用的磁盘缓存大小
        NSUInteger currentCacheSize = 0;

        // 在缓存的目录开始遍历文件.  此次遍历有两个目的:
        //  1. 移除过期的文件
        //  2. 同时存储每个文件的属性（比如该file是否是文件夹、该file所需磁盘大小，修改时间）
        NSMutableArray<NSURL *> *urlsToDelete = [[NSMutableArray alloc] init];
        for (NSURL *fileURL in fileEnumerator) {
            NSError *error;
            NSDictionary<NSString *, id> *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:&error];

            // 当前扫描的是目录，就跳过
            if (error || !resourceValues || [resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }

            // 移除过期文件(这里判断过期的方式：对比文件的最后一次修改日期和expirationDate谁更晚，如果expirationDate更晚，就认为该文件已经过期)
            NSDate *modifiedDate = resourceValues[cacheContentDateKey];
            if ([[modifiedDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }
            
            // 计算当前已经使用的cache大小,并将对应file的属性存到cacheFiles中
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            currentCacheSize += totalAllocatedSize.unsignedIntegerValue;
            cacheFiles[fileURL] = resourceValues;
        }

        // 根据需要移除文件的url来移除对应file
        for (NSURL *fileURL in urlsToDelete) {
            [self.fileManager removeItemAtURL:fileURL error:nil];
        }

                 
        // 如果我们当前cache的大小已经超过了允许配置的缓存大小，那就删除已经缓存的文件
        // 删除策略就是，首先删除修改时间更早的缓存文件
        if (self.config.maxCacheSize > 0 && currentCacheSize > self.config.maxCacheSize) {
            // 直接将当前cache大小降到允许最大的cache大小的一般
            // 预期的缓存大小
            const NSUInteger desiredCacheSize = self.config.maxCacheSize / 2;

            // 根据文件修改时间来给所有缓存文件排序，按照修改时间越早越在前的规则排序
            NSArray<NSURL *> *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                                     usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                         return [obj1[cacheContentDateKey] compare:obj2[cacheContentDateKey]];
                                                                     }];
             
            // 每次删除file后，就计算此时的cache的大小.
            // 如果此时的cache大小已经降到期望的大小了，就停止删除文件了
            for (NSURL *fileURL in sortedFiles) {
                if ([self.fileManager removeItemAtURL:fileURL error:nil]) {
                    // 获取该文件对应的属性
                    NSDictionary<NSString *, id> *resourceValues = cacheFiles[fileURL];
                    // 根据resourceValues获取该文件所需磁盘空间大小
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    // 计算当前cache大小
                    currentCacheSize -= totalAllocatedSize.unsignedIntegerValue;

                    if (currentCacheSize < desiredCacheSize) {
                        // 如果当前的缓存小于预期的缓存，结束删除file操作
                        break;
                    }
                }
            }
        }
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

//后台删除过期文件
- (void)backgroundDeleteOldFiles {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    //如果backgroundTask对应的时间结束了，任务还没有处理完成，则直接终止任务
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        //通过标记您的位置来清理任何未完成的任务业务
        //完全停止或结束任务。
        //当任务非正常终止的时候，做清理工作
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    
    //启动长时间运行的任务并立即返回。
    //图片清理结束以后，处理完成
    [self deleteOldFilesWithCompletionBlock:^{
        //清理完成以后，终止任务
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}

#pragma mark - 缓存信息

- (NSUInteger)getSize {
    __block NSUInteger size = 0;
    // 需要同步操作：等待队列self.ioQueue中的任务执行完后（有可能队列中的任务正在添加图片或者删除图片操作），再进行获取文件大小计算
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];
        for (NSString *fileName in fileEnumerator) {
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            NSDictionary<NSString *, id> *attrs = [self.fileManager attributesOfItemAtPath:filePath error:nil];
            size += [attrs fileSize];
        }
    });
    return size;
}

- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];
        count = fileEnumerator.allObjects.count;
    });
    return count;
}

- (void)calculateSizeWithCompletionBlock:(nullable LdzfFileCacheCalculateSizeBlock)completionBlock {
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;
        NSUInteger totalSize = 0;

        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:@[NSFileSize]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += fileSize.unsignedIntegerValue;
            fileCount += 1;
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}

@end



