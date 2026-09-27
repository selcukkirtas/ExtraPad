#import "include/VirtualDisplayBridge.h"

// ---------------------------------------------------------------------------
// Private CoreGraphics interfaces, declared here only so the compiler knows the
// selectors. Nothing is linked: instances come from NSClassFromString, so an
// absent class is a nil check rather than a link error or a crash.
// ---------------------------------------------------------------------------

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (assign) NSUInteger hiDPI;
@property (retain) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (copy) NSString *name;
@property (assign) NSUInteger maxPixelsWide;
@property (assign) NSUInteger maxPixelsHigh;
@property (assign) CGSize sizeInMillimeters;
@property (assign) uint32_t productID;
@property (assign) uint32_t vendorID;
@property (assign) uint32_t serialNum;
@property (retain) dispatch_queue_t queue;
@property (copy) void (^terminationHandler)(id a, id b);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) CGDirectDisplayID displayID;
@end

// ---------------------------------------------------------------------------

/// Assigns through KVC so a property that changed type or vanished in a macOS
/// update costs us one skipped field instead of an exception.
static void EPTrySet(id target, NSString *key, id value) {
    @try { [target setValue:value forKey:key]; }
    @catch (NSException *e) {
        NSLog(@"[ExtraPad] virtual display: '%@' ayarlanamadi (%@)", key, e.reason);
    }
}

@implementation EPVirtualDisplay {
    CGVirtualDisplay *_display;
    CGDirectDisplayID _displayID;
}

+ (BOOL)supported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (nullable instancetype)initWithName:(NSString *)name
                          pixelsWide:(NSUInteger)pixelsWide
                          pixelsHigh:(NSUInteger)pixelsHigh
                         refreshRate:(double)refreshRate
                               scale:(NSUInteger)scale {
    self = [super init];
    if (!self) { return nil; }
    if (!EPVirtualDisplay.supported) {
        NSLog(@"[ExtraPad] Bu macOS surumunde CGVirtualDisplay bulunamadi.");
        return nil;
    }

    CGVirtualDisplayDescriptor *descriptor =
        [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    if (!descriptor) { return nil; }

    EPTrySet(descriptor, @"name", name);
    EPTrySet(descriptor, @"maxPixelsWide", @(pixelsWide));
    EPTrySet(descriptor, @"maxPixelsHigh", @(pixelsHigh));
    // ~1 mm per 4.6 px keeps macOS from reporting an absurd physical size.
    EPTrySet(descriptor, @"sizeInMillimeters",
             [NSValue valueWithSize:NSMakeSize(pixelsWide / 4.6, pixelsHigh / 4.6)]);
    EPTrySet(descriptor, @"productID", @(0x1234));
    EPTrySet(descriptor, @"vendorID", @(0x3456));
    EPTrySet(descriptor, @"serialNum", @(0x0001));
    EPTrySet(descriptor, @"queue", dispatch_get_main_queue());
    EPTrySet(descriptor, @"terminationHandler", ^(id a, id b) {
        NSLog(@"[ExtraPad] Sanal ekran sonlandirildi.");
    });

    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc]
                initWithDescriptor:descriptor];
    if (!_display) {
        NSLog(@"[ExtraPad] Sanal ekran olusturulamadi.");
        return nil;
    }

    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                                  initWithWidth:pixelsWide
                                         height:pixelsHigh
                                    refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings =
        [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    if (!mode || !settings) { return nil; }

    EPTrySet(settings, @"hiDPI", @(scale >= 2 ? 1 : 0));
    EPTrySet(settings, @"modes", @[mode]);

    if (![_display applySettings:settings]) {
        NSLog(@"[ExtraPad] Sanal ekran modu uygulanamadi.");
        _display = nil;
        return nil;
    }

    _displayID = _display.displayID;
    NSLog(@"[ExtraPad] Sanal ekran hazir: id=%u %lux%lu@%.0fHz",
          _displayID, (unsigned long)pixelsWide, (unsigned long)pixelsHigh, refreshRate);
    return self;
}

- (CGDirectDisplayID)displayID { return _displayID; }

- (void)invalidate {
    _display = nil;   // releasing the object removes the display
    _displayID = 0;
}

- (void)dealloc { [self invalidate]; }

@end
