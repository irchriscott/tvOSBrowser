#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserNativeVideoAssetLoader.h"

#import <AVFoundation/AVFoundation.h>

static NSString * const kBrowserNativeVideoPlayerLogPrefix = @"[NativeVideoPlayer]";
static NSString * const kBrowserNativePlayerInputLogPrefix = @"[InputTrace][NativePlayer]";
static NSString * const kBrowserNativePlayerQualityDefaultsKey = @"NativePlayerPreferredQuality";

typedef struct {
    __unsafe_unretained NSString *identifier;
    __unsafe_unretained NSString *title;
    CGFloat width;
    CGFloat height;
} BrowserNativePlayerQuality;

/// Width/height 0 = no cap (Auto). The cap is a ceiling: AVPlayer still adapts
/// below it when bandwidth or the TV's display mode cannot sustain it.
static const BrowserNativePlayerQuality kBrowserNativePlayerQualities[] = {
    { @"auto", @"Auto", 0, 0 },
    { @"2160", @"4K (2160p)", 3840, 2160 },
    { @"1080", @"1080p", 1920, 1080 },
    { @"720", @"720p", 1280, 720 },
    { @"480", @"480p", 854, 480 },
};

static NSString *BrowserNativePlayerPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserNativePlayerPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserNativeVideoPlayerViewController ()

@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *requestCookies;
@property (nonatomic, strong) BrowserNativeVideoAssetLoader *assetLoader;
@property (nonatomic) BOOL didApplyStartTime;
@property (nonatomic, copy) NSArray<NSArray *> *subtitleCues;
@property (nonatomic, copy) NSString *subtitleLabelText;
@property (nonatomic) BOOL subtitlesEnabled;
@property (nonatomic) UIView *subtitleBackgroundView;
@property (nonatomic) UILabel *subtitleLabel;
@property (nonatomic, strong) id subtitleTimeObserver;
@property (nonatomic) NSUInteger subtitleCueHint;
@property (nonatomic) BOOL didReportDismissal;
@property (nonatomic, strong) AVAsset *asset;
/// Options for the Quality menu: dictionaries with id / title / subtitle / width / height.
/// Taken from the stream's own variants once they load (tvOS 15+), else a fixed list.
@property (nonatomic, copy) NSArray<NSDictionary *> *qualityOptions;
@property (nonatomic) BOOL qualityOptionsFromStream;
/// Seconds to seek to once the current item is ready (NAN = none), and whether to resume then.
@property (nonatomic) NSTimeInterval pendingSeekTime;
@property (nonatomic) BOOL resumeAfterPendingSeek;
@property (nonatomic) NSInteger playingTier;
@property (nonatomic) BOOL didRetryDirectly;

@end

@implementation BrowserNativeVideoPlayerViewController

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserNativeVideoPlayerLogPrefix, message);
}

- (instancetype)initWithURL:(NSURL *)URL title:(NSString *)title {
    return [self initWithURL:URL title:title requestHeaders:nil cookies:nil];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _requestCookies = [cookies copy] ?: @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    self.showsPlaybackControls = YES;
    if (@available(tvOS 11.2, *)) {
        // Let tvOS switch the TV to the video's frame rate / dynamic range (needs Settings >
        // Video and Audio > Match Content). 4K streams are often HDR-only, and HDR variants are
        // only chosen when the TV is in an HDR mode.
        self.appliesPreferredDisplayCriteriaAutomatically = YES;
    }
    BOOL viaLoader = (self.requestHeaders.count > 0 || self.requestCookies.count > 0) && ![self isHLSURL:self.videoURL];
    AVURLAsset *asset = [self makeAssetThroughLoader:viaLoader];
    [self log:@"using request headers %@ cookies=%lu loader=%d", self.requestHeaders, (unsigned long)self.requestCookies.count, viaLoader];
    self.asset = asset;
    self.pendingSeekTime = self.startTime > 1.0 ? self.startTime : NAN;
    self.playingTier = 0;
    self.qualityOptions = [self fixedQualityOptions];
    AVPlayerItem *playerItem = [self makePlayerItemWithQualityIdentifier:[self savedQualityIdentifier]];
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    [self startObservingItem:playerItem];
    [self setUpSubtitleOverlay];
    [self rebuildQualityMenu];
    [self loadStreamQualityOptions];
    [self log:@"created player url=%@ start=%.1f", self.videoURL.absoluteString ?: @"", self.startTime];

    if (@available(tvOS 10.0, *)) {
        [self.player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                         context:NULL];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSLog(@"%@ viewDidAppear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewDidAppear play"];
    [self.player play];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if ((self.isBeingDismissed || self.presentingViewController == nil) && !self.didReportDismissal) {
        self.didReportDismissal = YES;
        NSTimeInterval currentTime = CMTimeGetSeconds(self.player.currentTime);
        if (self.dismissHandler != nil && isfinite(currentTime)) {
            self.dismissHandler(currentTime);
        }
    }
}

#pragma mark - HLS & quality

- (NSDictionary *)assetOptions {
    NSMutableDictionary *assetOptions = [NSMutableDictionary dictionary];
    if (self.requestHeaders.count > 0) {
        assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = self.requestHeaders;
        NSString *userAgent = self.requestHeaders[@"User-Agent"];
        if (userAgent.length > 0) {
            assetOptions[@"AVURLAssetHTTPUserAgentKey"] = userAgent;
        }
    }
    if (self.requestCookies.count > 0) {
        assetOptions[@"AVURLAssetHTTPCookiesKey"] = self.requestCookies;
    }
    return assetOptions;
}

/// Direct: AVFoundation loads the URL itself and applies the headers to every playlist and
/// segment request (required for HLS: the custom resource loader cannot serve HLS media
/// segments - CoreMedia -12881, black screen). Loader: progressive files go through the custom
/// loader, which adds the page's headers/cookies.
- (AVURLAsset *)makeAssetThroughLoader:(BOOL)throughLoader {
    if (!throughLoader) {
        self.assetLoader = nil;
        return [AVURLAsset URLAssetWithURL:self.videoURL options:[self assetOptions]];
    }
    self.assetLoader = [[BrowserNativeVideoAssetLoader alloc] initWithRequestHeaders:self.requestHeaders cookies:self.requestCookies];
    NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:self.videoURL];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:[self assetOptions]];
    [self.assetLoader attachToAsset:asset];
    return asset;
}

/// Many sites serve HLS playlists from URLs without ".m3u8" (e.g. /vd/<token>), which then went
/// through the custom loader and failed with "Cannot Open" (-11829). Retry once, directly.
- (BOOL)retryDirectlyAfterFailure {
    if (self.assetLoader == nil || self.didRetryDirectly) {
        return NO;
    }
    self.didRetryDirectly = YES;
    NSTimeInterval position = CMTimeGetSeconds(self.player.currentTime);
    if (!isfinite(self.pendingSeekTime)) {
        self.pendingSeekTime = (isfinite(position) && position > 1.0) ? position : (self.startTime > 1.0 ? self.startTime : NAN);
    }
    self.resumeAfterPendingSeek = YES;
    [self log:@"loader playback failed; retrying directly (likely HLS without .m3u8)"];
    AVPlayerItem *oldItem = self.player.currentItem;
    self.asset = [self makeAssetThroughLoader:NO];
    AVPlayerItem *newItem = [self makePlayerItemWithQualityIdentifier:[self savedQualityIdentifier]];
    [self stopObservingItem:oldItem];
    [self.player replaceCurrentItemWithPlayerItem:newItem];
    [self startObservingItem:newItem];
    [self loadStreamQualityOptions];
    return YES;
}

- (BOOL)isHLSURL:(NSURL *)URL {
    NSString *path = URL.path.lowercaseString ?: @"";
    NSString *query = URL.query.lowercaseString ?: @"";
    return [path hasSuffix:@".m3u8"] || [query containsString:@"m3u8"];
}

/// Standard picture tier ("1080" for 1920x800 widescreen too) of a video size; 0 when unknown.
static NSInteger BrowserVideoTier(CGSize size) {
    CGFloat value = MAX(size.height, size.width * 9.0 / 16.0);
    if (value <= 0.0) {
        return 0;
    }
    static const NSInteger tiers[] = { 2160, 1440, 1080, 720, 576, 480, 360, 240 };
    for (NSUInteger index = 0; index < sizeof(tiers) / sizeof(tiers[0]); index++) {
        if (value >= tiers[index] * 0.9) {
            return tiers[index];
        }
    }
    return (NSInteger)lround(value);
}

static NSString *BrowserVideoTierTitle(NSInteger tier) {
    return tier == 2160 ? @"4K (2160p)" : [NSString stringWithFormat:@"%ldp", (long)tier];
}

- (NSString *)savedQualityIdentifier {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kBrowserNativePlayerQualityDefaultsKey] ?: @"auto";
}

- (NSArray<NSDictionary *> *)fixedQualityOptions {
    NSMutableArray *options = [NSMutableArray array];
    NSUInteger count = sizeof(kBrowserNativePlayerQualities) / sizeof(kBrowserNativePlayerQualities[0]);
    for (NSUInteger index = 0; index < count; index++) {
        BrowserNativePlayerQuality quality = kBrowserNativePlayerQualities[index];
        [options addObject:@{ @"id": quality.identifier, @"title": quality.title }];
    }
    return options;
}

/// The resolution ceiling for a quality: "1080" caps at 1920x1080 (plus a little slack for
/// odd encodes); auto has no cap. AVPlayer picks the best variant that fits under it.
- (CGSize)maximumResolutionForQualityIdentifier:(NSString *)identifier {
    NSInteger tier = identifier.integerValue;
    if (tier <= 0) {
        return CGSizeZero;
    }
    return CGSizeMake(ceil(tier * 16.0 / 9.0) + 8.0, tier + 8.0);
}

- (AVPlayerItem *)makePlayerItemWithQualityIdentifier:(NSString *)identifier {
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:self.asset];
    CGSize maximum = [self maximumResolutionForQualityIdentifier:identifier];
    if (@available(tvOS 11.0, *)) {
        item.preferredMaximumResolution = maximum;
    }
    item.preferredPeakBitRate = 0; // resolution is the only cap; bandwidth adaption stays automatic
    [self log:@"quality=%@ maxResolution=%.0fx%.0f", identifier, maximum.width, maximum.height];
    return item;
}

- (void)startObservingItem:(AVPlayerItem *)item {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemNewErrorLogEntry:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    [item addObserver:self forKeyPath:@"presentationSize" options:NSKeyValueObservingOptionNew context:NULL];
}

- (void)stopObservingItem:(AVPlayerItem *)item {
    if (item == nil) {
        return;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemNewErrorLogEntryNotification object:item];
    @try {
        [item removeObserver:self forKeyPath:@"status"];
        [item removeObserver:self forKeyPath:@"presentationSize"];
    } @catch (__unused NSException *exception) {}
}

/// Builds the Quality menu from the qualities the stream really offers (HLS variants), marking
/// HDR-only ones. Streams with one variant (or plain video files) cannot change quality.
- (void)loadStreamQualityOptions {
    if (@available(tvOS 15.0, *)) {
        if (![self.asset isKindOfClass:[AVURLAsset class]]) {
            return;
        }
        AVURLAsset *asset = (AVURLAsset *)self.asset;
        __weak typeof(self) weakSelf = self;
        [asset loadValuesAsynchronouslyForKeys:@[@"variants"] completionHandler:^{
            NSError *error = nil;
            AVKeyValueStatus status = [asset statusOfValueForKey:@"variants" error:&error];
            NSArray<AVAssetVariant *> *variants = status == AVKeyValueStatusLoaded ? asset.variants : @[];
            NSMutableDictionary<NSNumber *, NSMutableDictionary *> *tiers = [NSMutableDictionary dictionary];
            NSMutableArray<NSString *> *described = [NSMutableArray array];
            for (AVAssetVariant *variant in variants) {
                AVAssetVariantVideoAttributes *video = variant.videoAttributes;
                if (video == nil) {
                    continue;
                }
                NSInteger tier = BrowserVideoTier(video.presentationSize);
                if (tier <= 0) {
                    continue;
                }
                BOOL hdr = video.videoRange != nil && ![video.videoRange isEqualToString:AVVideoRangeSDR];
                NSMutableDictionary *entry = tiers[@(tier)] ?: [NSMutableDictionary dictionaryWithDictionary:@{ @"sdr": @NO, @"hdr": @NO }];
                entry[hdr ? @"hdr" : @"sdr"] = @YES;
                tiers[@(tier)] = entry;
                [described addObject:[NSString stringWithFormat:@"%.0fx%.0f/%@/%.0fkbps", video.presentationSize.width, video.presentationSize.height, video.videoRange ?: @"?", variant.peakBitRate / 1000.0]];
            }
            NSMutableArray<NSDictionary *> *options = [NSMutableArray arrayWithObject:@{ @"id": @"auto", @"title": @"Auto" }];
            NSArray<NSNumber *> *sortedTiers = [tiers.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
            for (NSNumber *tier in sortedTiers) {
                BOOL hdrOnly = [tiers[tier][@"hdr"] boolValue] && ![tiers[tier][@"sdr"] boolValue];
                NSString *title = BrowserVideoTierTitle(tier.integerValue);
                [options addObject:@{
                    @"id": tier.stringValue,
                    @"title": hdrOnly ? [title stringByAppendingString:@" HDR"] : title,
                    @"subtitle": hdrOnly ? @"Plays when the TV is in an HDR mode" : @"",
                }];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf.asset != asset) {
                    return; // the stream was reopened meanwhile
                }
                [strongSelf log:@"stream variants (%lu): %@", (unsigned long)variants.count, [described componentsJoinedByString:@", "]];
                strongSelf.qualityOptions = options;
                strongSelf.qualityOptionsFromStream = YES;
                [strongSelf rebuildQualityMenu];
            });
        }];
    }
}

- (BOOL)streamOffersQualityChoice {
    return !self.qualityOptionsFromStream || self.qualityOptions.count > 2;
}

/// Which option to tick for a saved preference: the exact one, else the highest offered below it.
- (NSString *)checkedQualityIdentifierForSaved:(NSString *)saved {
    NSInteger savedTier = saved.integerValue;
    if (savedTier <= 0) {
        return @"auto";
    }
    NSString *best = nil;
    NSString *lowest = nil;
    for (NSDictionary *option in self.qualityOptions) {
        NSInteger tier = [option[@"id"] integerValue];
        if (tier <= 0) {
            continue;
        }
        lowest = option[@"id"];
        if (best == nil && tier <= savedTier) {
            best = option[@"id"];
        }
    }
    return best ?: lowest ?: @"auto";
}

- (void)selectQualityWithIdentifier:(NSString *)identifier {
    NSString *previous = [self savedQualityIdentifier];
    [[NSUserDefaults standardUserDefaults] setObject:identifier forKey:kBrowserNativePlayerQualityDefaultsKey];
    AVPlayerItem *oldItem = self.player.currentItem;
    CGSize maximum = [self maximumResolutionForQualityIdentifier:identifier];
    BOOL changed = !CGSizeEqualToSize(maximum, [self maximumResolutionForQualityIdentifier:previous]);
    if (!changed || oldItem == nil || oldItem.status != AVPlayerItemStatusReadyToPlay || ![self streamOffersQualityChoice]) {
        if (@available(tvOS 11.0, *)) {
            oldItem.preferredMaximumResolution = maximum;
        }
        [self log:@"quality=%@ (applied to upcoming segments)", identifier];
        [self rebuildQualityMenu];
        return;
    }

    // AVPlayer keeps up to a minute of video buffered and only applies a new resolution cap to
    // segments it has yet to download, so the change would take that long to show. Restart the
    // stream from the same position with the new cap instead: the change is visible right away.
    NSTimeInterval position = CMTimeGetSeconds(self.player.currentTime);
    self.pendingSeekTime = isfinite(position) ? position : NAN;
    self.resumeAfterPendingSeek = self.player.rate > 0.0 || self.player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate;
    [self.player pause];
    AVPlayerItem *newItem = [self makePlayerItemWithQualityIdentifier:identifier];
    [self stopObservingItem:oldItem];
    [self log:@"switching quality to %@ at t=%.1f resume=%d", identifier, position, self.resumeAfterPendingSeek];
    [self.player replaceCurrentItemWithPlayerItem:newItem];
    [self startObservingItem:newItem];
    [self rebuildQualityMenu];
}

- (NSString *)qualityStateDescription {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSDictionary *option in self.qualityOptions) {
        [titles addObject:option[@"title"]];
    }
    return [NSString stringWithFormat:@"options=[%@] fromStream=%d saved=%@ playingTier=%ld maxResolution=%@",
            [titles componentsJoinedByString:@", "], self.qualityOptionsFromStream, [self savedQualityIdentifier],
            (long)self.playingTier, NSStringFromCGSize(self.player.currentItem.preferredMaximumResolution)];
}

#pragma mark - Subtitles from the web page

static NSTimeInterval BrowserSubtitleTime(NSString *value) {
    // Accepts HH:MM:SS,mmm / HH:MM:SS.mmm / MM:SS.mmm
    NSArray<NSString *> *parts = [[value stringByReplacingOccurrencesOfString:@"," withString:@"."] componentsSeparatedByString:@":"];
    NSTimeInterval seconds = 0.0;
    for (NSString *part in parts) {
        seconds = seconds * 60.0 + part.doubleValue;
    }
    return seconds;
}

- (void)setSubtitleText:(NSString *)text label:(NSString *)label {
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<NSArray *> *cues = [NSMutableArray array];
    for (NSString *block in [normalized componentsSeparatedByString:@"\n\n"]) {
        NSArray<NSString *> *lines = [block componentsSeparatedByString:@"\n"];
        NSUInteger timingIndex = NSNotFound;
        for (NSUInteger index = 0; index < lines.count; index++) {
            if ([lines[index] containsString:@"-->"]) {
                timingIndex = index;
                break;
            }
        }
        if (timingIndex == NSNotFound) {
            continue;
        }
        NSArray<NSString *> *times = [lines[timingIndex] componentsSeparatedByString:@"-->"];
        NSString *startString = [times.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *endString = [[[times.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@" "] firstObject];
        NSArray<NSString *> *textLines = [lines subarrayWithRange:NSMakeRange(timingIndex + 1, lines.count - timingIndex - 1)];
        NSString *cueText = [[textLines componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (cueText.length == 0) {
            continue;
        }
        [cues addObject:@[@(BrowserSubtitleTime(startString)), @(BrowserSubtitleTime(endString)), cueText]];
    }
    [self setSubtitleCues:cues label:label];
}

- (void)setSubtitleCues:(NSArray<NSArray *> *)cues label:(NSString *)label {
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>|\\{[^}]*\\}" options:0 error:nil];
    NSMutableArray<NSArray *> *cleaned = [NSMutableArray arrayWithCapacity:cues.count];
    for (NSArray *cue in cues) {
        if (cue.count < 3) {
            continue;
        }
        NSString *text = [cue[2] description];
        text = [tags stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
        text = [[text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"] stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
        [cleaned addObject:@[@([cue[0] doubleValue]), @([cue[1] doubleValue]), text]];
    }
    [cleaned sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    self.subtitleCues = cleaned;
    self.subtitleLabelText = label.length > 0 ? label : @"Website subtitles";
    self.subtitlesEnabled = cleaned.count > 0;
    self.subtitleCueHint = 0;
    [self log:@"subtitles: %lu cues (%@)", (unsigned long)cleaned.count, self.subtitleLabelText];
    if (self.isViewLoaded) {
        [self rebuildQualityMenu];
    }
}

- (void)setUpSubtitleOverlay {
    UIView *overlay = self.contentOverlayView;
    if (overlay == nil) {
        return;
    }
    self.subtitleBackgroundView = [UIView new];
    self.subtitleBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleBackgroundView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.subtitleBackgroundView.layer.cornerRadius = 12.0;
    self.subtitleBackgroundView.hidden = YES;
    [overlay addSubview:self.subtitleBackgroundView];

    self.subtitleLabel = [UILabel new];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.numberOfLines = 0;
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.textColor = UIColor.whiteColor;
    self.subtitleLabel.font = [UIFont systemFontOfSize:46.0 weight:UIFontWeightSemibold];
    self.subtitleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    self.subtitleLabel.layer.shadowOpacity = 0.9;
    self.subtitleLabel.layer.shadowRadius = 3.0;
    self.subtitleLabel.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    [self.subtitleBackgroundView addSubview:self.subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.subtitleBackgroundView.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [self.subtitleBackgroundView.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor constant:-90.0],
        [self.subtitleBackgroundView.widthAnchor constraintLessThanOrEqualToAnchor:overlay.widthAnchor multiplier:0.8],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.subtitleBackgroundView.leadingAnchor constant:24.0],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.subtitleBackgroundView.trailingAnchor constant:-24.0],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.subtitleBackgroundView.topAnchor constant:10.0],
        [self.subtitleLabel.bottomAnchor constraintEqualToAnchor:self.subtitleBackgroundView.bottomAnchor constant:-10.0],
    ]];

    __weak typeof(self) weakSelf = self;
    self.subtitleTimeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC)
                                                                          queue:dispatch_get_main_queue()
                                                                     usingBlock:^(CMTime time) {
        [weakSelf updateSubtitleForTime:CMTimeGetSeconds(time)];
    }];
}

- (void)updateSubtitleForTime:(NSTimeInterval)time {
    NSString *text = nil;
    NSArray<NSArray *> *cues = self.subtitleCues;
    if (self.subtitlesEnabled && cues.count > 0 && isfinite(time)) {
        // Cues are sorted; start near the last match since playback mostly moves forward.
        NSUInteger index = MIN(self.subtitleCueHint, cues.count - 1);
        if ([cues[index][0] doubleValue] > time) {
            index = 0;
        }
        for (; index < cues.count; index++) {
            NSArray *cue = cues[index];
            if ([cue[0] doubleValue] > time) {
                break;
            }
            if (time <= [cue[1] doubleValue]) {
                text = cue[2];
                self.subtitleCueHint = index;
                break;
            }
        }
    }
    if (![self.subtitleLabel.text isEqualToString:text ?: @""]) {
        self.subtitleLabel.text = text ?: @"";
    }
    self.subtitleBackgroundView.hidden = text.length == 0;
}

/// "Quality" in the player's transport bar (swipe down while playing).
- (void)rebuildQualityMenu {
    if (@available(tvOS 15.0, *)) {
        __weak typeof(self) weakSelf = self;
        NSMutableArray<UIMenuElement *> *qualityItems = [NSMutableArray array];
        if (self.playingTier > 0) {
            UIAction *playing = [UIAction actionWithTitle:[NSString stringWithFormat:@"Playing: %@", BrowserVideoTierTitle(self.playingTier)]
                                                    image:nil identifier:nil handler:^(__unused UIAction *sender) {}];
            playing.attributes = UIMenuElementAttributesDisabled;
            [qualityItems addObject:playing];
        }
        if ([self streamOffersQualityChoice]) {
            NSString *checked = [self checkedQualityIdentifierForSaved:[self savedQualityIdentifier]];
            NSMutableArray<UIAction *> *choices = [NSMutableArray array];
            for (NSDictionary *option in self.qualityOptions) {
                NSString *identifier = option[@"id"];
                UIAction *action = [UIAction actionWithTitle:option[@"title"] image:nil identifier:nil handler:^(__unused UIAction *sender) {
                    [weakSelf selectQualityWithIdentifier:identifier];
                }];
                NSString *subtitle = option[@"subtitle"];
                if (subtitle.length > 0) {
                    action.subtitle = subtitle;
                }
                action.state = [identifier isEqualToString:checked] ? UIMenuElementStateOn : UIMenuElementStateOff;
                [choices addObject:action];
            }
            [qualityItems addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                                  options:UIMenuOptionsDisplayInline | UIMenuOptionsSingleSelection
                                                 children:choices]];
        } else {
            UIAction *single = [UIAction actionWithTitle:@"This site offers one quality" image:nil identifier:nil handler:^(__unused UIAction *sender) {}];
            single.subtitle = @"Pick a quality or server on the website's own player";
            single.attributes = UIMenuElementAttributesDisabled;
            [qualityItems addObject:single];
        }
        UIMenu *menu = [UIMenu menuWithTitle:@"Quality"
                                       image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                  identifier:nil
                                     options:0
                                    children:qualityItems];
        NSMutableArray<UIMenuElement *> *menus = [NSMutableArray arrayWithObject:menu];
        if (self.subtitleCues.count > 0) {
            UIAction *off = [UIAction actionWithTitle:@"Off" image:nil identifier:nil handler:^(__unused UIAction *sender) {
                weakSelf.subtitlesEnabled = NO;
                [weakSelf updateSubtitleForTime:CMTimeGetSeconds(weakSelf.player.currentTime)];
                [weakSelf rebuildQualityMenu];
            }];
            UIAction *on = [UIAction actionWithTitle:self.subtitleLabelText image:nil identifier:nil handler:^(__unused UIAction *sender) {
                weakSelf.subtitlesEnabled = YES;
                [weakSelf updateSubtitleForTime:CMTimeGetSeconds(weakSelf.player.currentTime)];
                [weakSelf rebuildQualityMenu];
            }];
            off.state = self.subtitlesEnabled ? UIMenuElementStateOff : UIMenuElementStateOn;
            on.state = self.subtitlesEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;
            [menus addObject:[UIMenu menuWithTitle:@"Subtitles"
                                             image:[UIImage systemImageNamed:@"captions.bubble"]
                                        identifier:nil
                                           options:UIMenuOptionsSingleSelection
                                          children:@[off, on]]];
        }
        self.transportBarCustomMenuItems = menus;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewWillDisappear pause"];
    [self.player pause];
}

- (void)dealloc {
    if (self.subtitleTimeObserver != nil) {
        [self.player removeTimeObserver:self.subtitleTimeObserver];
    }
    [self stopObservingItem:self.player.currentItem];
    @try {
        [self.player removeObserver:self forKeyPath:@"timeControlStatus"];
    } @catch (__unused NSException *exception) {}
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)togglePlayback {
    if (self.player.rate > 0.0) {
        [self log:@"toggle pause"];
        [self.player pause];
    } else {
        [self log:@"toggle play"];
        [self.player play];
    }
}

- (void)skipByInterval:(NSTimeInterval)delta {
    if (self.player.currentItem == nil) {
        return;
    }

    NSTimeInterval currentTime = CMTimeGetSeconds(self.player.currentTime);
    if (!isfinite(currentTime)) {
        currentTime = 0.0;
    }

    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval targetTime = currentTime + delta;
    if (isfinite(duration) && duration > 0.0) {
        targetTime = MIN(MAX(targetTime, 0.0), MAX(duration - 0.05, 0.0));
    } else {
        targetTime = MAX(targetTime, 0.0);
    }

    [self log:@"seek delta=%0.3f from=%0.3f to=%0.3f", delta, currentTime, targetTime];
    CMTime seekTime = CMTimeMakeWithSeconds(targetTime, NSEC_PER_SEC);
    [self.player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)scrubByHorizontalDelta:(CGFloat)delta {
    // Approximate touch-surface horizontal movement to timeline seek.
    NSTimeInterval secondsDelta = (NSTimeInterval)delta / 4.0;
    if (fabs(secondsDelta) < 0.01) {
        return;
    }
    [self skipByInterval:secondsDelta];
}

- (void)closePlayer {
    [self log:@"close player"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handlePlayerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self log:@"failedToPlayToEnd error=%@", error];
}

- (void)handlePlayerItemNewErrorLogEntry:(NSNotification *)notification {
    AVPlayerItemErrorLog *errorLog = self.player.currentItem.errorLog;
    AVPlayerItemErrorLogEvent *lastEvent = errorLog.events.lastObject;
    [self log:@"errorLog domain=%@ status=%ld comment=%@ serverAddress=%@ playbackSessionID=%@",
     lastEvent.errorDomain ?: @"",
     (long)lastEvent.errorStatusCode,
     lastEvent.errorComment ?: @"",
     lastEvent.serverAddress ?: @"",
     lastEvent.playbackSessionID ?: @""];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == self.player.currentItem && [keyPath isEqualToString:@"status"]) {
        switch (self.player.currentItem.status) {
            case AVPlayerItemStatusUnknown:
                [self log:@"item status=unknown error=%@", self.player.currentItem.error];
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self log:@"item status=ready duration=%f likelyToKeepUp=%d bufferEmpty=%d presentationSize=%@",
                 CMTimeGetSeconds(self.player.currentItem.duration),
                 self.player.currentItem.isPlaybackLikelyToKeepUp,
                 self.player.currentItem.isPlaybackBufferEmpty,
                 NSStringFromCGSize(self.player.currentItem.presentationSize)];
                if (isfinite(self.pendingSeekTime)) {
                    NSTimeInterval target = self.pendingSeekTime;
                    BOOL resume = self.resumeAfterPendingSeek;
                    self.pendingSeekTime = NAN;
                    self.resumeAfterPendingSeek = NO;
                    self.didApplyStartTime = YES;
                    __weak typeof(self) weakSelf = self;
                    [self.player seekToTime:CMTimeMakeWithSeconds(target, NSEC_PER_SEC)
                            toleranceBefore:kCMTimeZero
                             toleranceAfter:kCMTimeZero
                          completionHandler:^(__unused BOOL finished) {
                        if (resume) {
                            [weakSelf.player play];
                        }
                    }];
                } else if (self.resumeAfterPendingSeek) {
                    self.resumeAfterPendingSeek = NO;
                    [self.player play];
                }
                break;
            case AVPlayerItemStatusFailed:
                [self log:@"item status=failed error=%@", self.player.currentItem.error];
                [self retryDirectlyAfterFailure];
                break;
        }
        return;
    }

    if (object == self.player.currentItem && [keyPath isEqualToString:@"presentationSize"]) {
        NSInteger tier = BrowserVideoTier(self.player.currentItem.presentationSize);
        if (tier > 0 && tier != self.playingTier) {
            self.playingTier = tier;
            [self log:@"now playing %@ (%@)", BrowserVideoTierTitle(tier), NSStringFromCGSize(self.player.currentItem.presentationSize)];
            [self rebuildQualityMenu];
        }
        return;
    }

    if (object == self.player && [keyPath isEqualToString:@"timeControlStatus"]) {
        if (@available(tvOS 10.0, *)) {
            NSString *status = @"unknown";
            switch (self.player.timeControlStatus) {
                case AVPlayerTimeControlStatusPaused:
                    status = @"paused";
                    break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    status = @"waiting";
                    break;
                case AVPlayerTimeControlStatusPlaying:
                    status = @"playing";
                    break;
            }
            [self log:@"timeControlStatus=%@ reason=%@", status, self.player.reasonForWaitingToPlay ?: @""];
            return;
        }
    }

    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesBegan type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesEnded type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesEnded:presses withEvent:event];
}

@end
