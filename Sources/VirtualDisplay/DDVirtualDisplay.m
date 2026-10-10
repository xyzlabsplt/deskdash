#import "DDVirtualDisplay.h"

#if !__has_feature(objc_arc)
#error "DDVirtualDisplay.m needs ARC"
#endif

// CoreGraphics' private virtual display classes, as declared in DeskPad's CGVirtualDisplayPrivate.h (MIT, Khaos Tian),
// trimmed to what is used here. The classes are looked up at run time, so a macOS without them gets nil, not a crash.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation DDVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height hiDPI:(BOOL)hiDPI {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass || width == 0 || height == 0) return nil;
    if (!(self = [super init])) return nil;

    NSUInteger scale = hiDPI ? 2 : 1;
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)(width * scale);
    descriptor.maxPixelsHigh = (unsigned int)(height * scale);
    // About 110 points per inch, a desktop monitor's: macOS sizes text and the default scaling from it.
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 110, height * 25.4 / 110);
    descriptor.vendorID = 0xDD;
    descriptor.productID = 0xDD01;
    descriptor.serialNum = 1;

    _display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!_display || _display.displayID == kCGNullDirectDisplay) return nil;

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[modeClass alloc] initWithWidth:width * scale height:height * scale refreshRate:60]];
    if (![_display applySettings:settings]) return nil;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
