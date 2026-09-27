#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps the private CGVirtualDisplay family (CoreGraphics). Apple ships no public
/// way to add a display, so this is the same route BetterDisplay and friends take.
/// Every call goes through the Objective-C runtime: if a future macOS renames or
/// removes a class, `supported` turns false instead of the process trapping.
@interface EPVirtualDisplay : NSObject

/// NO when the private classes are absent on this macOS build.
@property (class, readonly) BOOL supported;

/// Creates a virtual display advertising a single mode. Returns nil on failure.
/// `scale` 2 registers a HiDPI (Retina) mode; 1 keeps one pixel per point.
/// `serial` must differ between simultaneous displays: macOS treats two
/// descriptors with the same product, vendor and serial as the same monitor and
/// refuses to create the second one.
- (nullable instancetype)initWithName:(NSString *)name
                          pixelsWide:(NSUInteger)pixelsWide
                          pixelsHigh:(NSUInteger)pixelsHigh
                         refreshRate:(double)refreshRate
                               scale:(NSUInteger)scale
                              serial:(uint32_t)serial;

/// CGDirectDisplayID of the created display, 0 if it never came up.
@property (readonly) CGDirectDisplayID displayID;

/// Explicitly tears the display down; also happens on dealloc.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
