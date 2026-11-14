#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const BrowserAdBlockerDidBlockPopupNotification;

/// Blocks ads, trackers and pop-ups:
/// - a WebKit content rule list (network blocking + hiding common ad containers),
///   applied to every web view's user content controller;
/// - a pop-up policy for script-opened windows (pop-unders).
@interface BrowserAdBlocker : NSObject

@property (class, nonatomic, readonly) BrowserAdBlocker *sharedBlocker;
@property (nonatomic, getter=isEnabled) BOOL enabled;

/// Registers a web view's WKUserContentController; the rules are added once
/// compiled (and removed/re-added when the blocker is toggled).
- (void)attachToUserContentController:(id)userContentController;

/// YES when the URL's host is on the ad/tracker list.
- (BOOL)isBlockedURL:(nullable NSURL *)URL;

/// Whether a request to open a new tab/window should be refused.
/// navigationType is WebKit's (0 = link activated, -1 = other/script).
- (BOOL)shouldBlockPopupRequest:(nullable NSURLRequest *)request
                  navigationType:(NSInteger)navigationType
                      sourceURL:(nullable NSURL *)sourceURL;

@end

NS_ASSUME_NONNULL_END
