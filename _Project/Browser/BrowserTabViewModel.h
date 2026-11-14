#import <UIKit/UIKit.h>

@interface BrowserTabViewModel : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *URLString;
@property (nonatomic, strong) UIImage *snapshotImage;
@property (nonatomic) CGPoint savedScrollOffset;
@property (nonatomic) BOOL hasSavedScrollOffset;
@property (nonatomic) BOOL needsScrollRestore;
@property (nonatomic) BOOL showingHome;
/// The tab this one was opened from (link to a new tab); Back on its first page returns there.
@property (nonatomic, copy) NSString *openerIdentifier;

- (instancetype)initWithSessionRepresentation:(NSDictionary *)sessionRepresentation;
- (NSDictionary *)sessionRepresentation;

@end
