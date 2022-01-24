//
//  LdzfFileCacheConfig.h
//  LdzfFileCache
//
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, LdzfFileCacheConfigExpireType) {
    /**
     * 访问文件时，它将更新此值 （访问日期）
     */
    LdzfFileCacheConfigExpireTypeAccessDate,
    /**
     * 文件从磁盘缓存中获取 （修改日期）
     */
    LdzfFileCacheConfigExpireTypeModificationDate
};

@interface LdzfFileCacheConfig : NSObject
/**
* 是否使用内存缓存，默认YES
* 禁用内存缓存时，也会禁用弱内存缓存。
*/
@property (assign, nonatomic) BOOL shouldCacheImagesInMemory;

/**
 * 控制文件的弱内存缓存的选项.启用时, LDZFFileCache 的内存缓存将使用弱映射表在存储到内存的同时存储文件，并同时删除.
 * 但是当触发内存警告时，由于弱映射表没有强烈的图像实例引用，即使内存缓存本身被清除，UIImageViews或其他实时实例强烈保留的一些图像也可以再次恢复，以避免 稍后从磁盘缓存或网络重新查询。 这可能对这种情况有所帮助，例如，当app进入后台并清除内存时，会在重新输入前景后导致单元格闪烁。
 * 默认为YES。 您可以动态更改此选项。
 */
//是否使用弱内存缓存，默认为YES
@property (assign, nonatomic) BOOL shouldUseWeakMemoryCache;

/**
 * 从磁盘读取缓存时的读取选项
 * 默认为 0. 可以设置为 `NSDataReadingMappedIfSafe` 以提高性能.
 */
//磁盘缓存读取选项，枚举
@property (assign, nonatomic) NSDataReadingOptions diskCacheReadingOptions;

/**
 * 将缓存写入磁盘时的写入选项
 * 默认为 NSDataWritingAtomic. 可以将其设置为 `NSDataWritingWithoutOverwriting` 以防止覆盖现有文件
 */
//磁盘缓存写入选项，枚举
@property (assign, nonatomic) NSDataWritingOptions diskCacheWritingOptions;

/**
* 在缓存中保留图片的最长时间，秒为单位
*/
@property (assign, nonatomic) NSInteger maxCacheAge;

/**
* 缓存的最大值，字节为单位，默认为0，表示不做限制
*/
@property (assign, nonatomic) NSUInteger maxCacheSize;

/**
 * 清理磁盘缓存时将检查清理缓存的属性
 * 默认修改日期
 */
//缓存配置过期类型，枚举 ，默认修改日期
@property (assign, nonatomic) LdzfFileCacheConfigExpireType diskCacheExpireType;

@end
