#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserHomeView;
@class BrowserNavigationService;
@class BrowserPreferencesStore;
@class BrowserSessionStore;
@class BrowserTabViewModel;
@class BrowserTopBarView;
@class BrowserViewModel;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserTabCoordinatorHost <NSObject>

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController;
- (void)browserTabCoordinatorUpdateTextFontSize;
- (BOOL)browserTabCoordinatorIsCursorModeEnabled;
- (BOOL)browserTabCoordinatorIsTabOverviewVisible;
- (void)browserTabCoordinatorHomeVisibilityChanged:(BOOL)visible;
- (void)browserTabCoordinatorShowAddressEntry;
/// A focus-driven control handled a Select press; the cursor click path must ignore it.
- (void)browserTabCoordinatorDidConsumeSelectPress;

@end

@interface BrowserTabCoordinator : NSObject

@property (nonatomic, readonly, nullable) BrowserWebView *activeWebView;
@property (nonatomic, readonly, nullable) BrowserTabViewModel *activeTab;
@property (nonatomic, readonly) BOOL showingHome;
@property (nonatomic, readonly, nullable) BrowserHomeView *homeView;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;

- (instancetype)initWithHost:(id<BrowserTabCoordinatorHost>)host
                   viewModel:(BrowserViewModel *)viewModel
            preferencesStore:(BrowserPreferencesStore *)preferencesStore
           navigationService:(BrowserNavigationService *)navigationService
                sessionStore:(BrowserSessionStore *)sessionStore
           browserContainerView:(UIView *)browserContainerView
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView
     manualScrollPanRecognizer:(UIPanGestureRecognizer *)manualScrollPanRecognizer
             webViewDelegate:(id)webViewDelegate
         scrollViewAllowBounces:(BOOL)scrollViewAllowBounces NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)restoreInitialStateOrCreateFirstTab;
- (void)webViewDidAppear;
- (void)loadHomePage;
- (void)reloadHome;
/// Hides Home on the active tab so a navigation the user started becomes visible.
- (void)dismissHomeIfNeeded;
/// Hides Home and returns to the page it covers. Returns NO when there is no page.
- (BOOL)returnFromHomeToPage;
- (void)createNewTabLoadingHomePage:(BOOL)loadHomePage;
- (BOOL)createNewTabWithRequest:(NSURLRequest *)request;
- (void)switchToTabAtIndex:(NSInteger)tabIndex;
- (void)closeTabAtIndex:(NSInteger)tabIndex;
- (void)recreateActiveWebViewPreservingCurrentURL;
- (void)captureSnapshotForCurrentTab;
- (void)prepareTabOverviewThumbnails;
- (void)persistSession;
- (void)handleWebViewPanGesture:(UIPanGestureRecognizer *)gestureRecognizer;
- (void)webViewDidStartLoad:(id)webView;
- (void)webViewDidFinishLoad:(id)webView;
- (void)webView:(id)webView didChangeLoadProgress:(double)progress loading:(BOOL)loading;
- (void)webViewContentProcessDidTerminate:(id)webView;
/// Reloads the active tab if it is showing the "page stopped responding" overlay.
/// Returns YES when it did, so the caller can skip its own Select handling.
- (BOOL)reloadCrashedActiveTabIfNeeded;
- (void)prepareTabForRequest:(NSURLRequest *)request webView:(id)webView;
- (void)setTopNavigationVisible:(BOOL)visible;
- (BrowserTabViewModel *)tabForWebView:(id)webView;
- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request;

@end

NS_ASSUME_NONNULL_END
