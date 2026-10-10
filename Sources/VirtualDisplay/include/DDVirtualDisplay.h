#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A display that exists only in software, which macOS treats like a connected monitor: it can be the main display,
/// hold windows, and be streamed by remote desktop apps. It lasts as long as this object (or the process).
///
/// Built on CoreGraphics' private CGVirtualDisplay (macOS 11 and later), as BetterDisplay and DeskPad are. Private API:
/// it may change in any macOS update, and then the initializer returns nil.
@interface DDVirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// `width` and `height` in points. With `hiDPI` it renders at twice that in pixels, as a Retina display does.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                                hiDPI:(BOOL)hiDPI;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
