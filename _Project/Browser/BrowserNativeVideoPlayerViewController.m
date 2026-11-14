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
@property (nonatomic) BOOL didReportDismissal;

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
    AVPlayerItem *playerItem = nil;
    if (self.requestHeaders.count > 0 || self.requestCookies.count > 0) {
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
        AVURLAsset *asset = nil;
        if ([self isHLSURL:self.videoURL]) {
            // AVFoundation applies these headers to every playlist and segment request itself.
            // The custom resource loader cannot serve HLS media segments (CoreMedia -12881:
            // black screen), so HLS must not go through it.
            asset = [AVURLAsset URLAssetWithURL:self.videoURL options:assetOptions];
        } else {
            self.assetLoader = [[BrowserNativeVideoAssetLoader alloc] initWithRequestHeaders:self.requestHeaders cookies:self.requestCookies];
            NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:self.videoURL];
            asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
            [self.assetLoader attachToAsset:asset];
        }
        playerItem = [AVPlayerItem playerItemWithAsset:asset];
        [self log:@"using request headers %@ cookies=%lu", self.requestHeaders, (unsigned long)self.requestCookies.count];
    } else {
        playerItem = [AVPlayerItem playerItemWithURL:self.videoURL];
    }
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    [self applyQuality:[self savedQualityIndex]];
    [self rebuildQualityMenu];
    [self log:@"created player url=%@ start=%.1f", self.videoURL.absoluteString ?: @"", self.startTime];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:self.player.currentItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemNewErrorLogEntry:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:self.player.currentItem];

    [self.player.currentItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
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

- (BOOL)isHLSURL:(NSURL *)URL {
    NSString *path = URL.path.lowercaseString ?: @"";
    NSString *query = URL.query.lowercaseString ?: @"";
    return [path hasSuffix:@".m3u8"] || [query containsString:@"m3u8"];
}

- (NSUInteger)savedQualityIndex {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kBrowserNativePlayerQualityDefaultsKey] ?: @"auto";
    NSUInteger count = sizeof(kBrowserNativePlayerQualities) / sizeof(kBrowserNativePlayerQualities[0]);
    for (NSUInteger index = 0; index < count; index++) {
        if ([kBrowserNativePlayerQualities[index].identifier isEqualToString:saved]) {
            return index;
        }
    }
    return 0;
}

- (void)applyQuality:(NSUInteger)index {
    BrowserNativePlayerQuality quality = kBrowserNativePlayerQualities[index];
    AVPlayerItem *item = self.player.currentItem;
    if (@available(tvOS 11.0, *)) {
        item.preferredMaximumResolution = CGSizeMake(quality.width, quality.height);
    }
    item.preferredPeakBitRate = 0; // resolution is the only cap; bandwidth adaption stays automatic
    [self log:@"quality=%@ maxResolution=%.0fx%.0f", quality.identifier, quality.width, quality.height];
}

- (void)selectQuality:(NSUInteger)index {
    [[NSUserDefaults standardUserDefaults] setObject:kBrowserNativePlayerQualities[index].identifier forKey:kBrowserNativePlayerQualityDefaultsKey];
    [self applyQuality:index];
    [self rebuildQualityMenu];
}

/// "Quality" in the player's transport bar (swipe down while playing).
- (void)rebuildQualityMenu {
    if (@available(tvOS 15.0, *)) {
        NSUInteger selected = [self savedQualityIndex];
        NSUInteger count = sizeof(kBrowserNativePlayerQualities) / sizeof(kBrowserNativePlayerQualities[0]);
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        __weak typeof(self) weakSelf = self;
        for (NSUInteger index = 0; index < count; index++) {
            UIAction *action = [UIAction actionWithTitle:kBrowserNativePlayerQualities[index].title
                                                   image:nil
                                              identifier:nil
                                                 handler:^(__unused UIAction *sender) {
                [weakSelf selectQuality:index];
            }];
            action.state = index == selected ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        UIMenu *menu = [UIMenu menuWithTitle:@"Quality"
                                       image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                  identifier:nil
                                     options:UIMenuOptionsSingleSelection
                                    children:actions];
        self.transportBarCustomMenuItems = @[menu];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewWillDisappear pause"];
    [self.player pause];
}

- (void)dealloc {
    @try {
        [self.player.currentItem removeObserver:self forKeyPath:@"status"];
    } @catch (__unused NSException *exception) {}
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
                if (!self.didApplyStartTime && self.startTime > 1.0) {
                    self.didApplyStartTime = YES;
                    [self.player seekToTime:CMTimeMakeWithSeconds(self.startTime, NSEC_PER_SEC)
                            toleranceBefore:kCMTimeZero
                             toleranceAfter:kCMTimeZero
                          completionHandler:^(__unused BOOL finished) {}];
                }
                break;
            case AVPlayerItemStatusFailed:
                [self log:@"item status=failed error=%@", self.player.currentItem.error];
                break;
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
