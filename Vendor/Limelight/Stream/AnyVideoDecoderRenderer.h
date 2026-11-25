//
//  AnyVideoDecoderRenderer.h
//  Moonlight
//
//  The connection drives any renderer through this protocol, so the app can
//  choose its video path (texture drawables for the window, including SBS 3D)
//  without changing the Limelight core.
//

#include "Limelight.h"
#import "ConnectionCallbacks.h"

@protocol AnyVideoDecoderRenderer <NSObject>

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;

@optional

/// Human-readable color/format summary for the stats overlay.
- (NSString*)getColorDescription;

@end
