//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Connection.h"
#import "AnyVideoDecoderRenderer.h"

@interface StreamManager : NSOperation

/// The caller supplies the video renderer. It is created on the main thread
/// after the host accepts the session, so the app can size its texture from
/// the negotiated stream.
- (id) initWithConfig:(StreamConfiguration*)config rendererProvider:(id<AnyVideoDecoderRenderer> __strong (^)(void))rendererProvider connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void) stopStream;
- (void) stopStreamWithCompletion:(void (^)(void))completion;

- (NSString*) getStatsOverlayText;
- (BOOL) getVideoStats:(video_stats_t*)stats;

@end
