//
//  LdzfFileCache.h
//  LdzfFileCache
//
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LdzfFileCacheConfig.h"
#import "LdzfFileCacheCompat.h"

typedef NS_ENUM(NSInteger, LdzfFileCacheType) {
    /**
     * 数据不能用 SDWebImage 缓存，但能从网上下载 （不缓存）。
     */
    LdzfFileCacheTypeNone,
    /**
     * 数据从磁盘中获取（缓存到磁盘中）
     */
    LdzfFileCacheTypeDisk,
    /**
     * 数据从内存中获取（缓存到内存中）
     */
    LdzfFileCacheTypeMemory
};

typedef NS_OPTIONS(NSUInteger, LdzfFileCacheOptions) {
    /**
     * 默认情况下，当图像缓存在内存中时，我们不查询磁盘数据。 此选项可以强制同时查询磁盘数据。
     */
    LdzfFileCacheCacheQueryDataWhenInMemory = 1 << 0,
    /**
     * 默认情况下，我们同步查询内存缓存，异步查询磁盘缓存。 此选项可以强制同步查询磁盘缓存。
     */
    LdzfFileCacheCacheQueryDiskSync = 1 << 1,
};

//查询完成的block
typedef void(^LdzfFileCacheQueryCompletedBlock)(NSData * _Nullable data, LdzfFileCacheType cacheType);
//检查完成的block
typedef void(^LdzfFileCacheCheckCacheCompletionBlock)(BOOL isInCache);
//计算缓存大小的block
typedef void(^LdzfFileCacheCalculateSizeBlock)(NSUInteger fileCount, NSUInteger totalSize);

@interface LdzfFileCache : NSObject

#pragma mark - Properties
/**
 * 缓存配置对象，存储所有类型的设置
 */
@property (nonatomic, nonnull, readonly) LdzfFileCacheConfig *config;

/**
 * 设置缓存中最大的消耗的内存，这里计算的是内存中的像素个数
 */
@property (assign, nonatomic) NSUInteger maxMemoryCost;

/**
 * 缓存应持有的对象的的最大数量。
 */
@property (assign, nonatomic) NSUInteger maxMemoryCountLimit;

#pragma mark - Singleton and initialization

/**
 * 返回全局共享缓存实例
 *
 * @return LdzfFileCacheCache全局实例
 */
+ (nonnull instancetype)sharedCache;

/**
 * 使用特定命名空间初始化一个新的缓存存储，里面就是去获取磁盘缓存路径，然后在进行一系列的初始化操作
 *
 * @param ns 用于此缓存存储的命名空间
 */
- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns;

/**
 * 使用特定的命名空间和目录初始化一个新的缓存存储
 *
 * @param ns        用于此缓存存储的命名空间
 * @param directory 用于缓存磁盘映像的目录
 */
- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory NS_DESIGNATED_INITIALIZER;

#pragma mark - 缓存路径
//初始化磁盘缓存路径
- (nullable NSString *)makeDiskCachePath:(nonnull NSString*)fullNamespace;

/**
 * 添加只读缓存路径用来搜索由LdzfFileCacheCache预先缓存的数据
 * 如果想要预先加载的数据和应用程序捆绑在一起，则非常有用。去找数据也可以在这个路径中添加
 *
 * @param path 此只读缓存路径使用的路径
 */
- (void)addReadOnlyCachePath:(nonnull NSString *)path;

#pragma mark - 存储操作
/**
 * 根据key将数据data同步缓存到内存和磁盘中
 *
 *
 * @param bsiData  需要缓存的数据data
 * @param key       唯一的缓存图片的key,通常是图像的绝对URL
 */
- (void)storeBsiDataToDisk:(nullable NSData *)bsiData
                    forKey:(nullable NSString *)key
                completion:(nullable LdzfFileCacheNoParamsBlock)completionBlock;

/**
 * 根据key将数据data异步缓存到内存和磁盘中
 *
 * @param bsiData     服务器返回的二进制数据，此表示将用于磁盘存储
 * @param key            唯一的缓存数据的key,通常是图像的绝对URL
 * @param toDisk          是否缓存到磁盘中
 * @param completionBlock 操作完成后执行的块
 */
- (void)storeBsiDataToDisk:(nullable NSData *)bsiData
                    forKey:(nullable NSString *)key
                    toDisk:(BOOL)toDisk
                completion:(nullable LdzfFileCacheNoParamsBlock)completionBlock;

#pragma mark - 查询和检索操作
/**
 *  异步检查磁盘缓存中是否存在指定数据data，回调返回结果
 *
 *  @param key             描述url的key
 *  @param completionBlock 检查完成时要执行的块。
 *  @note  将在主队列上始终执行完成块
 */
- (void)diskBsiDataExistsWithKey:(nullable NSString *)key completion:(nullable LdzfFileCacheCheckCacheCompletionBlock)completionBlock;

/**
 *  同步检查磁盘缓存中是否存在数据data，直接返回结果
 *
 *  @param key             描述url的key
 */
- (BOOL)diskBsiDataExistsWithKey:(nullable NSString *)key;

/**
 *  根据key同步查询数据data
 *
 *  @param key 用来存储所需数据data唯一的key
 *  @return  根据key返回查找的图片，如果未找到，返回nil
 */
- (nullable NSData *)diskBsiDataForKey:(nullable NSString *)key;

/**
 * 异步查询缓存并在完成后调用完成的操作。
 *
 * @param key      用来存储所需图片唯一的key
 * @param doneBlock The completion block. 如果操作被取消，则不会被调用
 *
 * @return       包含缓存操作的NSOperation实例
 */
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key done:(nullable LdzfFileCacheQueryCompletedBlock)doneBlock;

/**
 * 异步查询缓存并在完成后调用完成的操作。
 *
 * @param key      用来存储所需图片唯一的key
 * @param options  用于指定用于此高速缓存查询的选项
 * @param doneBlock The completion block. 如果操作被取消，则不会被调用
 *
 * @return     包含缓存操作的NSOperation实例
 */
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key options:(LdzfFileCacheOptions)options done:(nullable LdzfFileCacheQueryCompletedBlock)doneBlock;

/**
 * 同步查询内存缓存
 *
 * @param key     用来存储所需图片唯一的key
 * @return 根据key返回查找的图片，如果未找到，返回nil
 */
- (nullable NSData *)bsiDataFromMemoryCacheForKey:(nullable NSString *)key;
/**
 * 同步查询磁盘缓存
 *
 * @param key 用来存储所需图片唯一的key
 * @return 根据key返回查找的图片，如果未找到，返回nil
 */
- (nullable NSData *)bsiDataFromDiskCacheForKey:(nullable NSString *)key;
/**
 * 检查缓存后，同步查询缓存（磁盘或内存）
 *
 * @param key 用来存储所需图片唯一的key
 * @return 根据key返回查找的图片，如果未找到，返回nil
 */
- (nullable NSData *)bsiDataFromCacheForKey:(nullable NSString *)key;
#pragma mark - 移除操作
/**
 * 从内存或者磁盘缓存中异步移除数据data
 *
 * @param key            唯一的图片缓存key
 * @param completion      删除图像后应执行的块（可选）
 */
- (void)removeBsiDataForKey:(nullable NSString *)key withCompletion:(nullable LdzfFileCacheNoParamsBlock)completion;

/**
 * 从内存和可选磁盘缓存中异步移除数据data
 *
 * @param key            唯一的图片缓存key
 * @param fromDisk        是否也从磁盘中移除
 * @param completion      删除图像后应执行的块（可选）
 */
- (void)removeBsiDataForKey:(nullable NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(nullable LdzfFileCacheNoParamsBlock)completion;

#pragma mark - 缓存清理操作
/**
 * 清理所有的内存缓存数据data
 */
- (void)clearMemory;

/**
 * 异步清除所有磁盘缓存的数据data。 非阻塞方法 - 立即返回。
 * @param completion   缓存过期完成后应执行的块（可选）
 */
- (void)clearDiskOnCompletion:(nullable LdzfFileCacheNoParamsBlock)completion;

/**
 * 异步从磁盘中删除所有过期的缓存数据data。 非阻塞方法 - 立即返回。
 * @param completionBlock 缓存过期完成后应执行的块（可选）
 */
- (void)deleteOldFilesWithCompletionBlock:(nullable LdzfFileCacheNoParamsBlock)completionBlock;

#pragma mark - 缓存信息
/**
 * 获取磁盘缓存使用的大小
 */
- (NSUInteger)getSize;

/**
 * 获取磁盘缓存中的数据data数量
 */
- (NSUInteger)getDiskCount;

/**
 * 异步计算磁盘缓存的大小。
 */
- (void)calculateSizeWithCompletionBlock:(nullable LdzfFileCacheCalculateSizeBlock)completionBlock;

#pragma mark - 缓存路径
/**
 *  需要根路径和key来查询文件所在的位置 (需要缓存路径根文件夹）
 *
 *  @param key  the key (可以使用cacheKeyForURL从url获取)
 *  @param path 缓存路径根文件夹
 *
 *  @return 缓存路径
 */
- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path;

/**
 *  根据key获取相应文件的默认的缓存路径
 *
 *  @param key the key (可以使用cacheKeyForURL从url获取)
 *
 *  @return 默认的缓存路径
 */
- (nullable NSString *)defaultCachePathForKey:(nullable NSString *)key;

@end

