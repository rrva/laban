// Creates a software display through CoreGraphics' private CGVirtualDisplay
// API (the one DeskPad and BetterDisplay use), prints its CGDirectDisplayID,
// and keeps it attached until SIGTERM/SIGINT. Exiting detaches the display,
// which macOS treats like unplugging a monitor: windows on it are moved to a
// remaining display. Used by scripts/run-display-unplug-repro.
//
// Build: clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//          scripts/virtual-display.m -o virtual-display
// Usage: virtual-display [width height [hidpi [main]]]
//   main=1 makes the virtual display the main (menu bar) display, like a
//   docked external monitor, so detaching it also moves the menu bar.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    unsigned int width = argc > 2 ? (unsigned int)atoi(argv[1]) : 1920;
    unsigned int height = argc > 2 ? (unsigned int)atoi(argv[2]) : 1080;
    unsigned int hidpi = argc > 3 ? (unsigned int)atoi(argv[3]) : 0;
    int makeMain = argc > 4 ? atoi(argv[4]) : 0;

    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = @"Laban Repro Display";
    descriptor.maxPixelsWide = width * (hidpi ? 2 : 1);
    descriptor.maxPixelsHigh = height * (hidpi ? 2 : 1);
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.276, height * 0.276);
    descriptor.serialNum = 0x4c42;
    descriptor.productID = 0x4c42;
    descriptor.vendorID = 0x4c42;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (display == nil) {
      fprintf(stderr, "virtual-display: CGVirtualDisplay creation failed\n");
      return 1;
    }
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hidpi;
    settings.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                             height:height
                                                        refreshRate:60] ];
    if (![display applySettings:settings]) {
      fprintf(stderr, "virtual-display: applySettings failed\n");
      return 1;
    }
    if (makeMain) {
      // The main display is the one at the global origin. Put the virtual
      // display there and every other display to its left.
      CGDisplayConfigRef config;
      CGBeginDisplayConfiguration(&config);
      CGConfigureDisplayOrigin(config, display.displayID, 0, 0);
      uint32_t count = 0;
      CGDirectDisplayID others[16];
      CGGetOnlineDisplayList(16, others, &count);
      int32_t x = 0;
      for (uint32_t i = 0; i < count; i++) {
        if (others[i] == display.displayID) continue;
        x -= (int32_t)CGDisplayPixelsWide(others[i]);
        CGConfigureDisplayOrigin(config, others[i], x, 0);
      }
      if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) != kCGErrorSuccess) {
        fprintf(stderr, "virtual-display: could not make the display main\n");
      }
    }
    printf("%u\n", display.displayID);
    fflush(stdout);

    // Exit (detaching the display) on SIGTERM/SIGINT.
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    dispatch_source_t term =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_t interrupt =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(term, ^{ exit(0); });
    dispatch_source_set_event_handler(interrupt, ^{ exit(0); });
    dispatch_resume(term);
    dispatch_resume(interrupt);
    dispatch_main();
  }
}
