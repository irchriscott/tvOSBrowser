#import <UIKit/UIKit.h>

@class BrowserHomeItem;
@class BrowserHomeView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserHomeViewDelegate <NSObject>

- (void)homeView:(BrowserHomeView *)homeView didSelectItem:(BrowserHomeItem *)item;
- (void)homeViewDidSelectSearch:(BrowserHomeView *)homeView;
- (void)homeView:(BrowserHomeView *)homeView didRequestOptionsForItem:(BrowserHomeItem *)item;

@end

/// Native (non-web) start page: browser wordmark, a search field, pinned sites
/// and recently closed tabs. Fully driven by the tvOS focus engine.
@interface BrowserHomeView : UIView

@property (nonatomic, weak, nullable) id<BrowserHomeViewDelegate> delegate;
/// Space reserved at the top for the browser's top bar (content scrolls under it).
@property (nonatomic) CGFloat contentTopInset;

/// Re-reads pinned and recently closed items from BrowserHomeStore.
- (void)reloadData;

/// Renders the current content into an image (used for the tab overview).
- (nullable UIImage *)snapshotImage;

@end

/// Rounded site icon: the site's own favicon when it can be fetched, otherwise a
/// coloured monogram. Shared by Home and the tab overview.
@interface BrowserSiteIconView : UIView

- (void)configureWithItem:(BrowserHomeItem *)item;
- (void)configureWithURLString:(nullable NSString *)URLString title:(nullable NSString *)title;

@end

NS_ASSUME_NONNULL_END
