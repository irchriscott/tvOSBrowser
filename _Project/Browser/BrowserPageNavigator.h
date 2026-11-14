#import <UIKit/UIKit.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BrowserPageNavigationDirection) {
    BrowserPageNavigationDirectionUp = 0,
    BrowserPageNavigationDirectionDown,
    BrowserPageNavigationDirectionLeft,
    BrowserPageNavigationDirectionRight
};

/// Outcome of a directional move, as reported by the page script.
typedef NS_ENUM(NSInteger, BrowserPageNavigationResult) {
    BrowserPageNavigationResultNone = 0,   // nothing to move to or scroll
    BrowserPageNavigationResultMoved,      // highlight moved to another element
    BrowserPageNavigationResultScrolled,   // no element that way: page scrolled instead
    BrowserPageNavigationResultTopEdge     // already at the top of the page going up
};

/// Apple TV–style navigation for web pages: the remote's arrow presses move a
/// highlight between links, buttons and other clickable elements, the page
/// scrolls to keep it visible (or scrolls by itself when nothing is further
/// that way), and Select activates the highlighted element.
@interface BrowserPageNavigator : NSObject

- (void)moveInDirection:(BrowserPageNavigationDirection)direction
                webView:(BrowserWebView *)webView
             completion:(nullable void (^)(BrowserPageNavigationResult result))completion;

/// Centre of the highlighted element in page (CSS) coordinates, scrolled into
/// view first. nil when nothing is highlighted. Runs synchronously: call it
/// outside of UIKit event handling.
- (nullable NSValue *)activationPointInWebView:(BrowserWebView *)webView;

/// Removes the highlight (e.g. when switching back to cursor mode).
- (void)clearInWebView:(nullable BrowserWebView *)webView;

@end

NS_ASSUME_NONNULL_END
