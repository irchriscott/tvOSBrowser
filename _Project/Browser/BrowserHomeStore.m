#import "BrowserHomeStore.h"

static NSString * const kFavoritesDefaultsKey = @"FAVORITES";
static NSString * const kRecentlyClosedDefaultsKey = @"BrowserRecentlyClosedTabs";
static NSString * const kDefaultPinsSeededDefaultsKey = @"BrowserDefaultFavoritesAdded";
static NSUInteger const kMaximumRecentlyClosedCount = 10;

static NSString *BrowserHomeTrimmedString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *BrowserHomeComparableURLString(NSString *URLString) {
    NSString *comparable = BrowserHomeTrimmedString(URLString).lowercaseString;
    while ([comparable hasSuffix:@"/"]) {
        comparable = [comparable substringToIndex:comparable.length - 1];
    }
    for (NSString *prefix in @[@"https://", @"http://"]) {
        if ([comparable hasPrefix:prefix]) {
            comparable = [comparable substringFromIndex:prefix.length];
            break;
        }
    }
    if ([comparable hasPrefix:@"www."]) {
        comparable = [comparable substringFromIndex:4];
    }
    return comparable;
}

@interface BrowserHomeItem ()

@property (nonatomic, readwrite) BrowserHomeItemKind kind;
@property (nonatomic, readwrite, copy) NSString *URLString;
@property (nonatomic, readwrite, copy) NSString *title;
@property (nonatomic, readwrite, copy) NSString *displayHost;

@end

@implementation BrowserHomeItem

+ (nullable instancetype)itemWithStoredEntry:(id)entry kind:(BrowserHomeItemKind)kind {
    if (![entry isKindOfClass:[NSArray class]] || [entry count] == 0) {
        return nil;
    }

    NSString *URLString = BrowserHomeTrimmedString([entry objectAtIndex:0]);
    if (URLString.length == 0) {
        return nil;
    }

    NSString *title = [entry count] > 1 ? BrowserHomeTrimmedString([entry objectAtIndex:1]) : @"";
    NSString *host = [NSURL URLWithString:URLString].host ?: @"";
    if ([host.lowercaseString hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }

    BrowserHomeItem *item = [BrowserHomeItem new];
    item.kind = kind;
    item.URLString = URLString;
    item.displayHost = host.length > 0 ? host : URLString;
    item.title = title.length > 0 ? title : item.displayHost;
    return item;
}

@end

@implementation BrowserHomeStore

+ (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

+ (NSUInteger)maximumRecentlyClosedCount {
    return kMaximumRecentlyClosedCount;
}

+ (NSArray<NSArray<NSString *> *> *)defaultPinnedEntries {
    return @[
        @[@"https://cinejoy.pk/", @"Cinejoy"],
        @[@"https://www.movy.sx/", @"Movy"],
        @[@"https://hesagoal.com/", @"Hesagoal"],
        @[@"https://gkstreams.click/", @"GK Streams"],
    ];
}

+ (BOOL)entries:(NSArray *)entries containURLString:(NSString *)URLString {
    NSString *comparable = BrowserHomeComparableURLString(URLString);
    for (id entry in entries) {
        if ([entry isKindOfClass:[NSArray class]] && [entry count] > 0 &&
            [BrowserHomeComparableURLString([entry objectAtIndex:0]) isEqualToString:comparable]) {
            return YES;
        }
    }
    return NO;
}

+ (void)seedDefaultPinnedSitesIfNeeded {
    NSUserDefaults *defaults = [self defaults];
    if ([defaults boolForKey:kDefaultPinsSeededDefaultsKey]) {
        return;
    }

    NSMutableArray *favorites = [[defaults arrayForKey:kFavoritesDefaultsKey] mutableCopy] ?: [NSMutableArray array];
    NSUInteger insertionIndex = 0;
    for (NSArray<NSString *> *entry in [self defaultPinnedEntries]) {
        if ([self entries:favorites containURLString:entry.firstObject]) {
            continue;
        }
        // Defaults go first so they lead the Home screen, in the requested order.
        [favorites insertObject:entry atIndex:insertionIndex++];
    }
    [defaults setObject:favorites forKey:kFavoritesDefaultsKey];
    [defaults setBool:YES forKey:kDefaultPinsSeededDefaultsKey];
}

+ (NSArray<BrowserHomeItem *> *)itemsForDefaultsKey:(NSString *)key kind:(BrowserHomeItemKind)kind {
    NSMutableArray<BrowserHomeItem *> *items = [NSMutableArray array];
    for (id entry in [[self defaults] arrayForKey:key]) {
        BrowserHomeItem *item = [BrowserHomeItem itemWithStoredEntry:entry kind:kind];
        if (item != nil) {
            [items addObject:item];
        }
    }
    return items;
}

+ (NSArray<BrowserHomeItem *> *)pinnedItems {
    return [self itemsForDefaultsKey:kFavoritesDefaultsKey kind:BrowserHomeItemKindPinned];
}

+ (NSArray<BrowserHomeItem *> *)recentlyClosedItems {
    NSArray<BrowserHomeItem *> *items = [self itemsForDefaultsKey:kRecentlyClosedDefaultsKey kind:BrowserHomeItemKindRecentlyClosed];
    if (items.count > kMaximumRecentlyClosedCount) {
        items = [items subarrayWithRange:NSMakeRange(0, kMaximumRecentlyClosedCount)];
    }
    return items;
}

+ (NSMutableArray *)entriesForDefaultsKey:(NSString *)key removingURLString:(NSString *)URLString {
    NSString *comparable = BrowserHomeComparableURLString(URLString);
    NSMutableArray *entries = [NSMutableArray array];
    for (id entry in [[self defaults] arrayForKey:key]) {
        if (![entry isKindOfClass:[NSArray class]] || [entry count] == 0) {
            continue;
        }
        if ([BrowserHomeComparableURLString([entry objectAtIndex:0]) isEqualToString:comparable]) {
            continue;
        }
        [entries addObject:entry];
    }
    return entries;
}

+ (void)recordClosedTabWithURLString:(NSString *)URLString title:(NSString *)title {
    NSString *trimmedURLString = BrowserHomeTrimmedString(URLString);
    NSString *scheme = [NSURL URLWithString:trimmedURLString].scheme.lowercaseString;
    if (trimmedURLString.length == 0 || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return;
    }

    NSMutableArray *entries = [self entriesForDefaultsKey:kRecentlyClosedDefaultsKey removingURLString:trimmedURLString];
    [entries insertObject:@[trimmedURLString, BrowserHomeTrimmedString(title)] atIndex:0];
    if (entries.count > kMaximumRecentlyClosedCount) {
        [entries removeObjectsInRange:NSMakeRange(kMaximumRecentlyClosedCount, entries.count - kMaximumRecentlyClosedCount)];
    }
    [[self defaults] setObject:entries forKey:kRecentlyClosedDefaultsKey];
}

+ (void)removeItem:(BrowserHomeItem *)item {
    NSString *key = item.kind == BrowserHomeItemKindPinned ? kFavoritesDefaultsKey : kRecentlyClosedDefaultsKey;
    NSMutableArray *entries = [self entriesForDefaultsKey:key removingURLString:item.URLString];
    [[self defaults] setObject:entries forKey:key];
}

+ (void)pinItem:(BrowserHomeItem *)item {
    NSMutableArray *favorites = [[[self defaults] arrayForKey:kFavoritesDefaultsKey] mutableCopy] ?: [NSMutableArray array];
    if (![self entries:favorites containURLString:item.URLString]) {
        [favorites addObject:@[item.URLString, item.title ?: @""]];
        [[self defaults] setObject:favorites forKey:kFavoritesDefaultsKey];
    }
}

+ (void)clearRecentlyClosed {
    [[self defaults] removeObjectForKey:kRecentlyClosedDefaultsKey];
}

@end
