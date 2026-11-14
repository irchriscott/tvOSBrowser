#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BrowserTopBarAction) {
    BrowserTopBarActionBack = 0,
    BrowserTopBarActionRefresh,
    BrowserTopBarActionForward,
    BrowserTopBarActionHome,
    BrowserTopBarActionTabs,
    BrowserTopBarActionURL,
    BrowserTopBarActionFullscreen,
    BrowserTopBarActionMenu
};

@class BrowserTopBarView;

@protocol BrowserTopBarViewDelegate <NSObject>

- (void)browserTopBarView:(BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action;

@end

@interface BrowserTopBarView : UIVisualEffectView

@property (nonatomic, weak, nullable) id<BrowserTopBarViewDelegate> delegate;
@property (nonatomic, readonly) UILabel *URLLabel;
@property (nonatomic, readonly) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, readonly, getter=isFocusModeActive) BOOL focusModeActive;

- (CGRect)interactiveFrameForView:(UIView *)view;
- (void)setFocusModeActive:(BOOL)focusModeActive;
- (nullable UIView *)preferredFocusItem;

/// Shows a page address in the address field (scheme and "www." are hidden,
/// a lock is shown for https). Pass nil to show the Home placeholder.
- (void)setDisplayedURLString:(nullable NSString *)URLString;
- (void)setBackEnabled:(BOOL)backEnabled forwardEnabled:(BOOL)forwardEnabled;
- (void)setTabCount:(NSUInteger)tabCount;
- (void)setHomeActive:(BOOL)homeActive;
/// Fills the address field left-to-right while a page loads and shows the spinner.
- (void)setLoadProgress:(double)progress loading:(BOOL)loading animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
