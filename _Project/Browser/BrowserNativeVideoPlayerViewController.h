#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoPlayerViewController : AVPlayerViewController

- (instancetype)initWithURL:(NSURL *)URL title:(nullable NSString *)title;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

/// Where playback starts (seconds), e.g. the page video's current position.
@property (nonatomic) NSTimeInterval startTime;
/// Called once the player is dismissed, with the position the user reached.
@property (nonatomic, copy, nullable) void (^dismissHandler)(NSTimeInterval currentTime);

/// Subtitles taken from the web page (SRT or WebVTT text), shown over the video.
- (void)setSubtitleText:(NSString *)text label:(nullable NSString *)label;
/// Subtitles as cues: arrays of @[start (s), end (s), text].
- (void)setSubtitleCues:(NSArray<NSArray *> *)cues label:(nullable NSString *)label;

/// Picks a quality ("auto", "2160", "1080", "720", "480"...), remembers it as the default and
/// applies it at once (the stream restarts from the same position with the new resolution cap).
- (void)selectQualityWithIdentifier:(NSString *)identifier;
/// Quality options, saved choice and playing resolution, for diagnostics.
- (NSString *)qualityStateDescription;

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
