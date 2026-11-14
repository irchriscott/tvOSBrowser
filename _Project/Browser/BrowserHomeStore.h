#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BrowserHomeItemKind) {
    BrowserHomeItemKindPinned = 0,
    BrowserHomeItemKindRecentlyClosed
};

@interface BrowserHomeItem : NSObject

@property (nonatomic, readonly) BrowserHomeItemKind kind;
@property (nonatomic, readonly, copy) NSString *URLString;
@property (nonatomic, readonly, copy) NSString *title;
/// Host without a leading "www.", or the URL string when it has no host.
@property (nonatomic, readonly, copy) NSString *displayHost;

@end

/// Persists the data shown on the native Home screen: pinned sites (stored in
/// the existing "FAVORITES" defaults key so the side menu stays in sync) and
/// the most recently closed tabs.
@interface BrowserHomeStore : NSObject

+ (NSUInteger)maximumRecentlyClosedCount;

/// Adds the default pinned sites once per install. Safe to call repeatedly.
+ (void)seedDefaultPinnedSitesIfNeeded;

+ (NSArray<BrowserHomeItem *> *)pinnedItems;
+ (NSArray<BrowserHomeItem *> *)recentlyClosedItems;

+ (void)recordClosedTabWithURLString:(NSString *)URLString title:(nullable NSString *)title;
+ (void)removeItem:(BrowserHomeItem *)item;
+ (void)pinItem:(BrowserHomeItem *)item;
+ (void)clearRecentlyClosed;

@end

NS_ASSUME_NONNULL_END
