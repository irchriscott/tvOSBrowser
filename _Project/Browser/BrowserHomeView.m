#import "BrowserHomeView.h"

#import <ImageIO/ImageIO.h>

#import "BrowserHomeStore.h"
#import "BrowserPreferencesStore.h"

static NSString * const kHomeBrowserName = @"tvOS Browser";

typedef NS_ENUM(NSInteger, BrowserHomeSection) {
    BrowserHomeSectionSearch = 0,
    BrowserHomeSectionPinned,
    BrowserHomeSectionRecentlyClosed,
    BrowserHomeSectionCount
};

static CGFloat const kHomeMaxGridWidth = 1560.0;
static CGFloat const kHomeMinSideInset = 120.0;
static CGFloat const kHomeSearchWidth = 980.0;
static CGFloat const kHomeSearchHeight = 84.0;
static NSInteger const kHomeTilesPerRow = 6;
static CGFloat const kHomeTileWidth = 200.0;
static CGFloat const kHomeTileCardHeight = 200.0;
static CGFloat const kHomeTileHeight = 252.0;
static NSInteger const kHomeRecentPerRow = 3;
static CGFloat const kHomeRecentSpacing = 36.0;
static CGFloat const kHomeRecentHeight = 124.0;
static CGFloat const kHomeEmptyHeight = 96.0;

static UIColor *BrowserHomeAccentColor(void) {
    return [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0];
}

static UIImage *BrowserHomeSymbol(NSString *name, CGFloat pointSize, UIFontWeight weight) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightForFontWeight(weight)];
    return [[UIImage systemImageNamed:name withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static void BrowserHomeApplyLift(UIView *view, BOOL focused, CGFloat scale, CGFloat cornerRadius) {
    view.transform = focused ? CGAffineTransformMakeScale(scale, scale) : CGAffineTransformIdentity;
    view.layer.shadowColor = UIColor.blackColor.CGColor;
    view.layer.shadowOpacity = focused ? 0.55 : 0.0;
    view.layer.shadowRadius = focused ? 22.0 : 0.0;
    view.layer.shadowOffset = CGSizeMake(0.0, focused ? 16.0 : 0.0);
    view.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:view.bounds cornerRadius:cornerRadius].CGPath;
}

#pragma mark - Favicon loading

/// Fetches a site's icon straight from the site itself (apple-touch-icon,
/// <link rel="icon">, then /favicon.ico) and caches it on disk.
@interface BrowserFaviconLoader : NSObject

+ (instancetype)sharedLoader;
- (nullable UIImage *)cachedIconForURLString:(NSString *)URLString;
- (void)loadIconForURLString:(NSString *)URLString completion:(void (^)(UIImage * _Nullable image))completion;

@end

@interface BrowserFaviconLoader ()

@property (nonatomic) NSCache<NSString *, UIImage *> *memoryCache;
@property (nonatomic) NSMutableSet<NSString *> *failedKeys;
@property (nonatomic) NSMutableDictionary<NSString *, NSMutableArray *> *pendingCompletions;
@property (nonatomic) NSURLSession *session;

@end

@implementation BrowserFaviconLoader

+ (instancetype)sharedLoader {
    static BrowserFaviconLoader *loader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loader = [BrowserFaviconLoader new];
    });
    return loader;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memoryCache = [NSCache new];
        _failedKeys = [NSMutableSet set];
        _pendingCompletions = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.HTTPAdditionalHeaders = @{ @"User-Agent": BrowserPreferencesStore.desktopUserAgent ?: @"" };
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (nullable NSString *)cacheKeyForURLString:(NSString *)URLString {
    NSString *host = [NSURL URLWithString:URLString].host.lowercaseString;
    if (host.length == 0) {
        return nil;
    }
    NSCharacterSet *disallowed = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789.-"] invertedSet];
    return [[host componentsSeparatedByCharactersInSet:disallowed] componentsJoinedByString:@"_"];
}

- (NSURL *)diskURLForKey:(NSString *)key {
    NSURL *cachesURL = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directoryURL = [cachesURL URLByAppendingPathComponent:@"BrowserFavicons" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    return [directoryURL URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"png"]];
}

- (UIImage *)cachedIconForURLString:(NSString *)URLString {
    NSString *key = [self cacheKeyForURLString:URLString];
    if (key == nil) {
        return nil;
    }
    UIImage *image = [self.memoryCache objectForKey:key];
    if (image != nil) {
        return image;
    }
    NSData *data = [NSData dataWithContentsOfURL:[self diskURLForKey:key]];
    image = data.length > 0 ? [UIImage imageWithData:data] : nil;
    if (image != nil) {
        [self.memoryCache setObject:image forKey:key];
    }
    return image;
}

- (void)loadIconForURLString:(NSString *)URLString completion:(void (^)(UIImage *))completion {
    NSString *key = [self cacheKeyForURLString:URLString];
    NSURL *pageURL = [NSURL URLWithString:URLString];
    if (key == nil || pageURL == nil) {
        completion(nil);
        return;
    }

    UIImage *cachedImage = [self cachedIconForURLString:URLString];
    if (cachedImage != nil || [self.failedKeys containsObject:key]) {
        completion(cachedImage);
        return;
    }

    NSMutableArray *pending = self.pendingCompletions[key];
    if (pending != nil) {
        [pending addObject:[completion copy]];
        return;
    }
    self.pendingCompletions[key] = [NSMutableArray arrayWithObject:[completion copy]];

    NSURLComponents *components = [NSURLComponents new];
    components.scheme = pageURL.scheme.length > 0 ? pageURL.scheme : @"https";
    components.host = pageURL.host;
    components.port = pageURL.port;
    components.path = @"/";
    NSURL *originURL = components.URL;

    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithURL:originURL completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        NSURL *baseURL = response.URL ?: originURL;
        NSMutableArray<NSURL *> *candidates = [[weakSelf iconCandidatesInHTMLData:data baseURL:baseURL] mutableCopy];
        for (NSURL *base in @[baseURL, originURL]) {
            for (NSString *path in @[@"/apple-touch-icon.png", @"/favicon.ico"]) {
                NSURL *candidate = [NSURL URLWithString:path relativeToURL:base].absoluteURL;
                if (candidate != nil && ![candidates containsObject:candidate]) {
                    [candidates addObject:candidate];
                }
            }
        }
        [weakSelf tryCandidates:candidates index:0 key:key];
    }] resume];
}

- (NSArray<NSURL *> *)iconCandidatesInHTMLData:(NSData *)data baseURL:(NSURL *)baseURL {
    if (data.length == 0) {
        return @[];
    }
    NSData *headData = data.length > 300000 ? [data subdataWithRange:NSMakeRange(0, 300000)] : data;
    NSString *HTML = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding] ?:
        [[NSString alloc] initWithData:headData encoding:NSISOLatin1StringEncoding];
    if (HTML.length == 0) {
        return @[];
    }

    NSRegularExpression *linkExpression = [NSRegularExpression regularExpressionWithPattern:@"<link\\s[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *relExpression = [NSRegularExpression regularExpressionWithPattern:@"rel\\s*=\\s*[\"']([^\"']+)[\"']" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *hrefExpression = [NSRegularExpression regularExpressionWithPattern:@"href\\s*=\\s*[\"']([^\"']+)[\"']" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *sizesExpression = [NSRegularExpression regularExpressionWithPattern:@"sizes\\s*=\\s*[\"'](\\d+)x\\d+" options:NSRegularExpressionCaseInsensitive error:nil];

    NSMutableArray<NSDictionary *> *scored = [NSMutableArray array];
    for (NSTextCheckingResult *linkMatch in [linkExpression matchesInString:HTML options:0 range:NSMakeRange(0, HTML.length)]) {
        NSString *tag = [HTML substringWithRange:linkMatch.range];
        NSRange tagRange = NSMakeRange(0, tag.length);
        NSTextCheckingResult *relMatch = [relExpression firstMatchInString:tag options:0 range:tagRange];
        NSTextCheckingResult *hrefMatch = [hrefExpression firstMatchInString:tag options:0 range:tagRange];
        if (relMatch == nil || hrefMatch == nil) {
            continue;
        }
        NSString *rel = [tag substringWithRange:[relMatch rangeAtIndex:1]].lowercaseString;
        NSString *href = [[tag substringWithRange:[hrefMatch rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        if ([rel rangeOfString:@"icon"].location == NSNotFound || [rel rangeOfString:@"mask-icon"].location != NSNotFound ||
            [href.lowercaseString rangeOfString:@".svg"].location != NSNotFound) {
            continue;
        }
        NSURL *URL = [NSURL URLWithString:href relativeToURL:baseURL].absoluteURL;
        if (URL == nil) {
            continue;
        }
        NSTextCheckingResult *sizesMatch = [sizesExpression firstMatchInString:tag options:0 range:tagRange];
        NSInteger size = sizesMatch != nil ? [[tag substringWithRange:[sizesMatch rangeAtIndex:1]] integerValue] : 0;
        NSInteger score = ([rel rangeOfString:@"apple-touch-icon"].location != NSNotFound ? 10000 : 0) + MIN(size, 512);
        [scored addObject:@{ @"url": URL, @"score": @(score) }];
    }

    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"score"] compare:a[@"score"]];
    }];
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    for (NSDictionary *entry in scored) {
        if (![candidates containsObject:entry[@"url"]]) {
            [candidates addObject:entry[@"url"]];
        }
    }
    return candidates;
}

- (nullable UIImage *)largestImageInData:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (source == NULL) {
        return nil;
    }
    size_t count = CGImageSourceGetCount(source);
    size_t bestIndex = 0;
    CGFloat bestWidth = 0.0;
    for (size_t index = 0; index < count; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
        CGFloat width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        if (width > bestWidth) {
            bestWidth = width;
            bestIndex = index;
        }
    }
    CGImageRef imageRef = count > 0 ? CGImageSourceCreateImageAtIndex(source, bestIndex, NULL) : NULL;
    CFRelease(source);
    if (imageRef == NULL) {
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    return MIN(image.size.width, image.size.height) >= 16.0 ? image : nil;
}

- (void)tryCandidates:(NSArray<NSURL *> *)candidates index:(NSUInteger)index key:(NSString *)key {
    if (index >= candidates.count) {
        [self finishLoadingForKey:key image:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithURL:candidates[index] completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = (statusCode >= 200 && statusCode < 300) ? [weakSelf largestImageInData:data] : nil;
        if (image == nil) {
            [weakSelf tryCandidates:candidates index:index + 1 key:key];
            return;
        }
        NSData *PNGData = UIImagePNGRepresentation(image);
        if (PNGData != nil) {
            [PNGData writeToURL:[weakSelf diskURLForKey:key] atomically:YES];
        }
        [weakSelf finishLoadingForKey:key image:image];
    }] resume];
}

- (void)finishLoadingForKey:(NSString *)key image:(nullable UIImage *)image {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (image != nil) {
            [self.memoryCache setObject:image forKey:key];
        } else {
            [self.failedKeys addObject:key];
        }
        NSArray *completions = self.pendingCompletions[key];
        [self.pendingCompletions removeObjectForKey:key];
        for (void (^completion)(UIImage *) in completions) {
            completion(image);
        }
    });
}

@end

#pragma mark - Site icon view

@interface BrowserSiteIconView ()

@property (nonatomic) UIImageView *imageView;
@property (nonatomic) UILabel *monogramLabel;
@property (nonatomic, copy) NSString *URLString;

@end

@implementation BrowserSiteIconView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;

        _monogramLabel = [UILabel new];
        _monogramLabel.textAlignment = NSTextAlignmentCenter;
        _monogramLabel.textColor = UIColor.whiteColor;
        [self addSubview:_monogramLabel];

        _imageView = [UIImageView new];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_imageView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = CGRectGetWidth(self.bounds);
    self.layer.cornerRadius = round(side * 0.24);
    self.monogramLabel.frame = self.bounds;
    self.monogramLabel.font = [UIFont systemFontOfSize:round(side * 0.46) weight:UIFontWeightBold];
    self.imageView.frame = CGRectInset(self.bounds, round(side * 0.14), round(side * 0.14));
}

+ (UIColor *)monogramColorForSeed:(NSString *)seed {
    NSArray<UIColor *> *palette = @[
        [UIColor colorWithRed:0.93 green:0.30 blue:0.36 alpha:1.0],
        [UIColor colorWithRed:0.98 green:0.55 blue:0.20 alpha:1.0],
        [UIColor colorWithRed:0.20 green:0.70 blue:0.45 alpha:1.0],
        [UIColor colorWithRed:0.16 green:0.62 blue:0.86 alpha:1.0],
        [UIColor colorWithRed:0.42 green:0.40 blue:0.92 alpha:1.0],
        [UIColor colorWithRed:0.78 green:0.32 blue:0.80 alpha:1.0],
        [UIColor colorWithRed:0.12 green:0.66 blue:0.66 alpha:1.0],
    ];
    NSUInteger hash = 0;
    for (NSUInteger index = 0; index < seed.length; index++) {
        hash = (hash * 31) + [seed characterAtIndex:index];
    }
    return palette[hash % palette.count];
}

+ (NSString *)monogramForTitle:(NSString *)title host:(NSString *)host {
    NSCharacterSet *alphanumerics = [NSCharacterSet alphanumericCharacterSet];
    for (NSString *source in @[title ?: @"", host ?: @""]) {
        for (NSUInteger index = 0; index < source.length; index++) {
            unichar character = [source characterAtIndex:index];
            if ([alphanumerics characterIsMember:character]) {
                return [[NSString stringWithCharacters:&character length:1] uppercaseString];
            }
        }
    }
    return @"•";
}

- (void)showImage:(nullable UIImage *)image {
    self.imageView.image = image;
    self.imageView.hidden = image == nil;
    self.monogramLabel.hidden = image != nil;
    self.backgroundColor = image != nil ? UIColor.whiteColor : [BrowserSiteIconView monogramColorForSeed:self.URLString ?: @""];
}

- (void)configureWithItem:(BrowserHomeItem *)item {
    [self configureWithURLString:item.URLString title:item.title];
}

- (void)configureWithURLString:(NSString *)URLString title:(NSString *)title {
    URLString = URLString ?: @"";
    self.URLString = URLString;
    NSString *host = [NSURL URLWithString:URLString].host;
    if ([host.lowercaseString hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    self.monogramLabel.text = [BrowserSiteIconView monogramForTitle:title host:host];
    if (URLString.length == 0) {
        [self showImage:nil];
        return;
    }

    BrowserFaviconLoader *loader = [BrowserFaviconLoader sharedLoader];
    [self showImage:[loader cachedIconForURLString:URLString]];
    if (self.imageView.image != nil) {
        return;
    }

    NSString *requestedURLString = URLString;
    __weak typeof(self) weakSelf = self;
    [loader loadIconForURLString:requestedURLString completion:^(UIImage *image) {
        if (image == nil || ![weakSelf.URLString isEqualToString:requestedURLString]) {
            return;
        }
        [UIView transitionWithView:weakSelf duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            [weakSelf showImage:image];
        } completion:nil];
    }];
}

@end

#pragma mark - Cells

@interface BrowserHomeSearchCell : UICollectionViewCell
@property (nonatomic) UIView *pillView;
@property (nonatomic) UIImageView *iconView;
@property (nonatomic) UILabel *placeholderLabel;
@end

@implementation BrowserHomeSearchCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _pillView = [UIView new];
        _pillView.layer.cornerRadius = kHomeSearchHeight / 2.0;
        _pillView.layer.borderWidth = 1.0;
        [self.contentView addSubview:_pillView];

        _iconView = [[UIImageView alloc] initWithImage:BrowserHomeSymbol(@"magnifyingglass", 30.0, UIFontWeightSemibold)];
        _iconView.contentMode = UIViewContentModeCenter;
        [_pillView addSubview:_iconView];

        _placeholderLabel = [UILabel new];
        _placeholderLabel.text = @"Search or enter website address";
        _placeholderLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightMedium];
        [_pillView addSubview:_placeholderLabel];

        self.accessibilityLabel = _placeholderLabel.text;
        [self updateAppearance];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.pillView.bounds = self.contentView.bounds;
    self.pillView.center = CGPointMake(CGRectGetMidX(self.contentView.bounds), CGRectGetMidY(self.contentView.bounds));
    CGFloat height = CGRectGetHeight(self.pillView.bounds);
    self.iconView.frame = CGRectMake(30.0, 0.0, 40.0, height);
    self.placeholderLabel.frame = CGRectMake(88.0, 0.0, CGRectGetWidth(self.pillView.bounds) - 118.0, height);
    BrowserHomeApplyLift(self.pillView, self.isFocused, 1.04, kHomeSearchHeight / 2.0);
}

- (void)updateAppearance {
    BOOL focused = self.isFocused;
    self.pillView.backgroundColor = focused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.10];
    self.pillView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.0 : 0.12].CGColor;
    UIColor *contentColor = focused ? [UIColor colorWithWhite:0.15 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.55];
    self.iconView.tintColor = contentColor;
    self.placeholderLabel.textColor = contentColor;
    BrowserHomeApplyLift(self.pillView, focused, 1.04, kHomeSearchHeight / 2.0);
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearance];
    } completion:nil];
}

@end

@interface BrowserHomeTileCell : UICollectionViewCell
@property (nonatomic) UIView *cardView;
@property (nonatomic) BrowserSiteIconView *iconView;
@property (nonatomic) UILabel *titleLabel;
- (void)configureWithItem:(BrowserHomeItem *)item;
@end

@implementation BrowserHomeTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _cardView = [UIView new];
        _cardView.layer.cornerRadius = 36.0;
        _cardView.layer.borderWidth = 1.0;
        [self.contentView addSubview:_cardView];

        _iconView = [BrowserSiteIconView new];
        [_cardView addSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_titleLabel];
        [self updateAppearance];
    }
    return self;
}

- (void)configureWithItem:(BrowserHomeItem *)item {
    self.titleLabel.text = item.title;
    self.accessibilityLabel = item.title;
    [self.iconView configureWithItem:item];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    self.cardView.bounds = CGRectMake(0.0, 0.0, width, kHomeTileCardHeight);
    self.cardView.center = CGPointMake(width / 2.0, kHomeTileCardHeight / 2.0);
    CGFloat iconSide = 112.0;
    self.iconView.frame = CGRectMake((width - iconSide) / 2.0, (kHomeTileCardHeight - iconSide) / 2.0, iconSide, iconSide);
    [self layoutTitleLabel];
    BrowserHomeApplyLift(self.cardView, self.isFocused, 1.1, 36.0);
}

- (void)layoutTitleLabel {
    // Push the label down while focused so the lifted card never covers it.
    CGFloat offset = self.isFocused ? 14.0 : 0.0;
    self.titleLabel.frame = CGRectMake(-10.0, kHomeTileCardHeight + 16.0 + offset, CGRectGetWidth(self.contentView.bounds) + 20.0, 34.0);
}

- (void)updateAppearance {
    BOOL focused = self.isFocused;
    self.cardView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.22 : 0.08];
    self.cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.28 : 0.08].CGColor;
    self.titleLabel.textColor = focused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.72];
    self.titleLabel.font = [UIFont systemFontOfSize:25.0 weight:focused ? UIFontWeightSemibold : UIFontWeightMedium];
    BrowserHomeApplyLift(self.cardView, focused, 1.1, 36.0);
    [self layoutTitleLabel];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearance];
    } completion:nil];
}

@end

@interface BrowserHomeRecentCell : UICollectionViewCell
@property (nonatomic) UIView *cardView;
@property (nonatomic) BrowserSiteIconView *iconView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *hostLabel;
- (void)configureWithItem:(BrowserHomeItem *)item;
@end

@implementation BrowserHomeRecentCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _cardView = [UIView new];
        _cardView.layer.cornerRadius = 26.0;
        _cardView.layer.borderWidth = 1.0;
        [self.contentView addSubview:_cardView];

        _iconView = [BrowserSiteIconView new];
        [_cardView addSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightSemibold];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardView addSubview:_titleLabel];

        _hostLabel = [UILabel new];
        _hostLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
        _hostLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_cardView addSubview:_hostLabel];
        [self updateAppearance];
    }
    return self;
}

- (void)configureWithItem:(BrowserHomeItem *)item {
    self.titleLabel.text = item.title;
    self.hostLabel.text = item.displayHost;
    self.accessibilityLabel = item.title;
    [self.iconView configureWithItem:item];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.cardView.bounds = self.contentView.bounds;
    self.cardView.center = CGPointMake(CGRectGetMidX(self.contentView.bounds), CGRectGetMidY(self.contentView.bounds));
    CGFloat height = CGRectGetHeight(self.cardView.bounds);
    CGFloat iconSide = 72.0;
    self.iconView.frame = CGRectMake(26.0, (height - iconSide) / 2.0, iconSide, iconSide);
    CGFloat textX = CGRectGetMaxX(self.iconView.frame) + 22.0;
    CGFloat textWidth = CGRectGetWidth(self.cardView.bounds) - textX - 24.0;
    self.titleLabel.frame = CGRectMake(textX, height / 2.0 - 36.0, textWidth, 36.0);
    self.hostLabel.frame = CGRectMake(textX, height / 2.0 + 2.0, textWidth, 30.0);
    BrowserHomeApplyLift(self.cardView, self.isFocused, 1.05, 26.0);
}

- (void)updateAppearance {
    BOOL focused = self.isFocused;
    self.cardView.backgroundColor = focused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.08];
    self.cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.0 : 0.08].CGColor;
    self.titleLabel.textColor = focused ? [UIColor colorWithWhite:0.08 alpha:1.0] : UIColor.whiteColor;
    self.hostLabel.textColor = focused ? [UIColor colorWithWhite:0.0 alpha:0.5] : [UIColor colorWithWhite:1.0 alpha:0.5];
    BrowserHomeApplyLift(self.cardView, focused, 1.05, 26.0);
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearance];
    } completion:nil];
}

@end

@interface BrowserHomeEmptyCell : UICollectionViewCell
@property (nonatomic) UILabel *messageLabel;
@end

@implementation BrowserHomeEmptyCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIView *backgroundView = [[UIView alloc] initWithFrame:self.contentView.bounds];
        backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        backgroundView.layer.cornerRadius = 26.0;
        backgroundView.layer.borderWidth = 2.0;
        backgroundView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        [self.contentView addSubview:backgroundView];

        _messageLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.contentView.bounds, 36.0, 0.0)];
        _messageLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _messageLabel.font = [UIFont systemFontOfSize:25.0 weight:UIFontWeightRegular];
        _messageLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        [self.contentView addSubview:_messageLabel];
    }
    return self;
}

- (BOOL)canBecomeFocused {
    return NO;
}

@end

#pragma mark - Supplementary views

@interface BrowserHomeHeroView : UICollectionReusableView
@end

@implementation BrowserHomeHeroView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIView *glyphView = [UIView new];
        glyphView.translatesAutoresizingMaskIntoConstraints = NO;
        glyphView.layer.cornerRadius = 28.0;
        glyphView.clipsToBounds = YES;

        CAGradientLayer *gradientLayer = [CAGradientLayer layer];
        gradientLayer.frame = CGRectMake(0.0, 0.0, 108.0, 108.0);
        gradientLayer.colors = @[
            (id)[UIColor colorWithRed:0.30 green:0.66 blue:1.0 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.20 green:0.36 blue:0.95 alpha:1.0].CGColor,
        ];
        gradientLayer.startPoint = CGPointMake(0.0, 0.0);
        gradientLayer.endPoint = CGPointMake(1.0, 1.0);
        [glyphView.layer addSublayer:gradientLayer];

        UIImageView *globeView = [[UIImageView alloc] initWithImage:BrowserHomeSymbol(@"globe", 58.0, UIFontWeightMedium)];
        globeView.translatesAutoresizingMaskIntoConstraints = NO;
        globeView.tintColor = UIColor.whiteColor;
        [glyphView addSubview:globeView];

        UILabel *wordmarkLabel = [UILabel new];
        wordmarkLabel.translatesAutoresizingMaskIntoConstraints = NO;
        NSMutableAttributedString *wordmark = [[NSMutableAttributedString alloc] initWithString:@"tvOS "
                                                                                     attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:76.0 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName: UIColor.whiteColor,
        }];
        NSString *productName = [kHomeBrowserName hasPrefix:@"tvOS "] ? [kHomeBrowserName substringFromIndex:5] : kHomeBrowserName;
        [wordmark appendAttributedString:[[NSAttributedString alloc] initWithString:productName
                                                                         attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:76.0 weight:UIFontWeightLight],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85],
        }]];
        wordmarkLabel.attributedText = wordmark;
        wordmarkLabel.accessibilityLabel = kHomeBrowserName;

        UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[glyphView, wordmarkLabel]];
        stackView.translatesAutoresizingMaskIntoConstraints = NO;
        stackView.axis = UILayoutConstraintAxisHorizontal;
        stackView.alignment = UIStackViewAlignmentCenter;
        stackView.spacing = 30.0;
        [self addSubview:stackView];

        [NSLayoutConstraint activateConstraints:@[
            [glyphView.widthAnchor constraintEqualToConstant:108.0],
            [glyphView.heightAnchor constraintEqualToConstant:108.0],
            [globeView.centerXAnchor constraintEqualToAnchor:glyphView.centerXAnchor],
            [globeView.centerYAnchor constraintEqualToAnchor:glyphView.centerYAnchor],
            [stackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stackView.topAnchor constraintEqualToAnchor:self.topAnchor constant:20.0],
        ]];
    }
    return self;
}

@end

@interface BrowserHomeSectionHeaderView : UICollectionReusableView
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *hintLabel;
@property (nonatomic) CGFloat horizontalInset;
@end

@implementation BrowserHomeSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightBold];
        _titleLabel.textColor = UIColor.whiteColor;
        [self addSubview:_titleLabel];

        _hintLabel = [UILabel new];
        _hintLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightMedium];
        _hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.38];
        _hintLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_hintLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds) - (self.horizontalInset * 2.0);
    CGFloat labelY = CGRectGetHeight(self.bounds) - 62.0;
    self.titleLabel.frame = CGRectMake(self.horizontalInset, labelY, width * 0.6, 44.0);
    self.hintLabel.frame = CGRectMake(self.horizontalInset + width * 0.4, labelY + 8.0, width * 0.6, 32.0);
}

@end

#pragma mark - Layout

/// Flow layout that keeps partially filled rows left-aligned instead of
/// spreading their items across the full row width.
@interface BrowserHomeLeftAlignedFlowLayout : UICollectionViewFlowLayout
@end

@implementation BrowserHomeLeftAlignedFlowLayout

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray *attributes = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *original in [super layoutAttributesForElementsInRect:rect]) {
        if (original.representedElementCategory == UICollectionElementCategoryCell) {
            [attributes addObject:[self layoutAttributesForItemAtIndexPath:original.indexPath]];
        } else {
            [attributes addObject:[original copy]];
        }
    }
    return attributes;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *attributes = [[super layoutAttributesForItemAtIndexPath:indexPath] copy];
    id<UICollectionViewDelegateFlowLayout> delegate = (id<UICollectionViewDelegateFlowLayout>)self.collectionView.delegate;
    UIEdgeInsets sectionInset = [delegate collectionView:self.collectionView layout:self insetForSectionAtIndex:indexPath.section];
    CGFloat spacing = [delegate collectionView:self.collectionView layout:self minimumInteritemSpacingForSectionAtIndex:indexPath.section];

    CGRect frame = attributes.frame;
    frame.origin.x = sectionInset.left;
    if (indexPath.item > 0) {
        NSIndexPath *previousIndexPath = [NSIndexPath indexPathForItem:indexPath.item - 1 inSection:indexPath.section];
        CGRect previousFrame = [self layoutAttributesForItemAtIndexPath:previousIndexPath].frame;
        if (fabs(CGRectGetMidY(previousFrame) - CGRectGetMidY(frame)) < 1.0) {
            frame.origin.x = CGRectGetMaxX(previousFrame) + spacing;
        }
    }
    attributes.frame = frame;
    return attributes;
}

@end

#pragma mark - Home view

@interface BrowserHomeView () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>

@property (nonatomic) CAGradientLayer *backgroundGradientLayer;
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) NSArray<BrowserHomeItem *> *pinnedItems;
@property (nonatomic) NSArray<BrowserHomeItem *> *recentItems;
@property (nonatomic) CGFloat lastLayoutWidth;

@end

@implementation BrowserHomeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _pinnedItems = @[];
        _recentItems = @[];

        _backgroundGradientLayer = [CAGradientLayer layer];
        _backgroundGradientLayer.colors = @[
            (id)[UIColor colorWithRed:0.13 green:0.14 blue:0.20 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.06 green:0.06 blue:0.09 alpha:1.0].CGColor,
        ];
        _backgroundGradientLayer.startPoint = CGPointMake(0.5, 0.0);
        _backgroundGradientLayer.endPoint = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:_backgroundGradientLayer];

        BrowserHomeLeftAlignedFlowLayout *layout = [BrowserHomeLeftAlignedFlowLayout new];
        layout.scrollDirection = UICollectionViewScrollDirectionVertical;

        _collectionView = [[UICollectionView alloc] initWithFrame:self.bounds collectionViewLayout:layout];
        _collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _collectionView.backgroundColor = UIColor.clearColor;
        _collectionView.clipsToBounds = NO;
        _collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        _collectionView.showsVerticalScrollIndicator = NO;
        _collectionView.remembersLastFocusedIndexPath = YES;
        _collectionView.dataSource = self;
        _collectionView.delegate = self;
        [_collectionView registerClass:[BrowserHomeSearchCell class] forCellWithReuseIdentifier:@"Search"];
        [_collectionView registerClass:[BrowserHomeTileCell class] forCellWithReuseIdentifier:@"Tile"];
        [_collectionView registerClass:[BrowserHomeRecentCell class] forCellWithReuseIdentifier:@"Recent"];
        [_collectionView registerClass:[BrowserHomeEmptyCell class] forCellWithReuseIdentifier:@"Empty"];
        [_collectionView registerClass:[BrowserHomeHeroView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"Hero"];
        [_collectionView registerClass:[BrowserHomeSectionHeaderView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"Header"];
        [self addSubview:_collectionView];

        UILongPressGestureRecognizer *longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
        longPressRecognizer.minimumPressDuration = 0.6;
        [_collectionView addGestureRecognizer:longPressRecognizer];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.backgroundGradientLayer.frame = self.bounds;
    [CATransaction commit];

    CGFloat topInset = MAX(self.safeAreaInsets.top, self.contentTopInset) + 24.0;
    UIEdgeInsets contentInset = UIEdgeInsetsMake(topInset, 0.0, MAX(self.safeAreaInsets.bottom, 60.0), 0.0);
    if (!UIEdgeInsetsEqualToEdgeInsets(self.collectionView.contentInset, contentInset)) {
        self.collectionView.contentInset = contentInset;
    }
    if (CGRectGetWidth(self.bounds) != self.lastLayoutWidth) {
        self.lastLayoutWidth = CGRectGetWidth(self.bounds);
        [self.collectionView.collectionViewLayout invalidateLayout];
        [self.collectionView reloadData];
    }
}

- (void)setContentTopInset:(CGFloat)contentTopInset {
    if (_contentTopInset == contentTopInset) {
        return;
    }
    _contentTopInset = contentTopInset;
    [self setNeedsLayout];
}

- (void)reloadData {
    self.pinnedItems = [BrowserHomeStore pinnedItems];
    self.recentItems = [BrowserHomeStore recentlyClosedItems];
    [self.collectionView reloadData];
}

- (UIImage *)snapshotImage {
    if (CGRectIsEmpty(self.bounds)) {
        return nil;
    }
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:self.bounds];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [self drawViewHierarchyInRect:self.bounds afterScreenUpdates:NO];
    }];
}

#pragma mark Geometry

- (CGFloat)gridWidth {
    CGFloat available = CGRectGetWidth(self.collectionView.bounds) - (kHomeMinSideInset * 2.0);
    return MAX(MIN(kHomeMaxGridWidth, available), 600.0);
}

- (CGFloat)gridInset {
    return floor((CGRectGetWidth(self.collectionView.bounds) - [self gridWidth]) / 2.0);
}

- (CGFloat)tileSpacing {
    return floor(([self gridWidth] - (kHomeTilesPerRow * kHomeTileWidth)) / (kHomeTilesPerRow - 1));
}

- (CGFloat)recentCardWidth {
    return floor(([self gridWidth] - ((kHomeRecentPerRow - 1) * kHomeRecentSpacing)) / kHomeRecentPerRow);
}

#pragma mark Focus

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.collectionView];
}

- (NSIndexPath *)indexPathForPreferredFocusedViewInCollectionView:(__unused UICollectionView *)collectionView {
    if (self.pinnedItems.count > 0) {
        return [NSIndexPath indexPathForItem:0 inSection:BrowserHomeSectionPinned];
    }
    return [NSIndexPath indexPathForItem:0 inSection:BrowserHomeSectionSearch];
}

- (BOOL)collectionView:(__unused UICollectionView *)collectionView canFocusItemAtIndexPath:(NSIndexPath *)indexPath {
    return [self itemAtIndexPath:indexPath] != nil || indexPath.section == BrowserHomeSectionSearch;
}

- (nullable BrowserHomeItem *)itemAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<BrowserHomeItem *> *items = nil;
    if (indexPath.section == BrowserHomeSectionPinned) {
        items = self.pinnedItems;
    } else if (indexPath.section == BrowserHomeSectionRecentlyClosed) {
        items = self.recentItems;
    }
    return indexPath.item < items.count ? items[indexPath.item] : nil;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        if (![self.collectionView cellForItemAtIndexPath:indexPath].isFocused) {
            continue;
        }
        BrowserHomeItem *item = [self itemAtIndexPath:indexPath];
        if (item != nil) {
            [self.delegate homeView:self didRequestOptionsForItem:item];
        }
        return;
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(__unused CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    // When focus heads back up to the search field, show the whole wordmark too.
    CGFloat topOffset = -scrollView.contentInset.top;
    if (targetContentOffset->y < topOffset + 320.0) {
        targetContentOffset->y = topOffset;
    }
}

#pragma mark UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(__unused UICollectionView *)collectionView {
    return BrowserHomeSectionCount;
}

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    switch (section) {
        case BrowserHomeSectionSearch:
            return 1;
        case BrowserHomeSectionPinned:
            return MAX(self.pinnedItems.count, 1);
        case BrowserHomeSectionRecentlyClosed:
            return MAX(self.recentItems.count, 1);
        default:
            return 0;
    }
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == BrowserHomeSectionSearch) {
        return [collectionView dequeueReusableCellWithReuseIdentifier:@"Search" forIndexPath:indexPath];
    }

    BrowserHomeItem *item = [self itemAtIndexPath:indexPath];
    if (item == nil) {
        BrowserHomeEmptyCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Empty" forIndexPath:indexPath];
        cell.messageLabel.text = indexPath.section == BrowserHomeSectionPinned
            ? @"No pinned sites yet. Open the menu and choose Favorites → Add Current Page."
            : @"Tabs you close will show up here.";
        return cell;
    }

    if (indexPath.section == BrowserHomeSectionPinned) {
        BrowserHomeTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Tile" forIndexPath:indexPath];
        [cell configureWithItem:item];
        return cell;
    }

    BrowserHomeRecentCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Recent" forIndexPath:indexPath];
    [cell configureWithItem:item];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == BrowserHomeSectionSearch) {
        return [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"Hero" forIndexPath:indexPath];
    }

    BrowserHomeSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"Header" forIndexPath:indexPath];
    header.horizontalInset = [self gridInset];
    BOOL pinned = indexPath.section == BrowserHomeSectionPinned;
    NSUInteger count = pinned ? self.pinnedItems.count : self.recentItems.count;
    header.titleLabel.text = pinned ? @"Pinned" : @"Recently Closed";
    header.hintLabel.text = count > 0 ? @"Press and hold for options" : @"";
    [header setNeedsLayout];
    return header;
}

#pragma mark UICollectionViewDelegateFlowLayout

- (void)collectionView:(__unused UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == BrowserHomeSectionSearch) {
        [self.delegate homeViewDidSelectSearch:self];
        return;
    }
    BrowserHomeItem *item = [self itemAtIndexPath:indexPath];
    if (item != nil) {
        [self.delegate homeView:self didSelectItem:item];
    }
}

- (CGSize)collectionView:(__unused UICollectionView *)collectionView layout:(__unused UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case BrowserHomeSectionSearch:
            return CGSizeMake(MIN(kHomeSearchWidth, [self gridWidth]), kHomeSearchHeight);
        case BrowserHomeSectionPinned:
            return self.pinnedItems.count > 0 ? CGSizeMake(kHomeTileWidth, kHomeTileHeight) : CGSizeMake([self gridWidth], kHomeEmptyHeight);
        default:
            return self.recentItems.count > 0 ? CGSizeMake([self recentCardWidth], kHomeRecentHeight) : CGSizeMake([self gridWidth], kHomeEmptyHeight);
    }
}

- (UIEdgeInsets)collectionView:(__unused UICollectionView *)collectionView layout:(__unused UICollectionViewLayout *)layout insetForSectionAtIndex:(NSInteger)section {
    if (section == BrowserHomeSectionSearch) {
        CGFloat searchInset = floor((CGRectGetWidth(self.collectionView.bounds) - MIN(kHomeSearchWidth, [self gridWidth])) / 2.0);
        return UIEdgeInsetsMake(0.0, searchInset, 30.0, searchInset);
    }
    CGFloat bottom = section == BrowserHomeSectionPinned ? 20.0 : 40.0;
    return UIEdgeInsetsMake(0.0, [self gridInset], bottom, [self gridInset]);
}

- (CGFloat)collectionView:(__unused UICollectionView *)collectionView layout:(__unused UICollectionViewLayout *)layout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    return section == BrowserHomeSectionPinned ? [self tileSpacing] : kHomeRecentSpacing;
}

- (CGFloat)collectionView:(__unused UICollectionView *)collectionView layout:(__unused UICollectionViewLayout *)layout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    return section == BrowserHomeSectionPinned ? 40.0 : 32.0;
}

- (CGSize)collectionView:(__unused UICollectionView *)collectionView layout:(__unused UICollectionViewLayout *)layout referenceSizeForHeaderInSection:(NSInteger)section {
    CGFloat width = CGRectGetWidth(self.collectionView.bounds);
    return CGSizeMake(width, section == BrowserHomeSectionSearch ? 196.0 : 96.0);
}

@end
