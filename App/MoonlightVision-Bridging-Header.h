//
//  MoonlightVision-Bridging-Header.h
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Exposes the vendored core to Swift.
//

#import "AppDelegate.h"
#import "DataManager.h"
#import "DiscoveryManager.h"
#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "TemporarySettings.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "ServerInfoResponse.h"
#import "AppListResponse.h"
#import "AppAssetManager.h"
#import "ConnectionHelper.h"
#import "PairManager.h"
#import "WakeOnLanManager.h"
#import "StreamConfiguration.h"
#import "StreamManager.h"
#import "Connection.h"
#import "ConnectionCallbacks.h"
#import "HDRParsingUtils.h"
#import "ControllerSupport.h"
#import "KeyboardSupport.h"

#include <Limelight.h>
#import "Audio/MVAudioRing.h"
#import "Audio/MVAudioConfig.h"
#include "opus_multistream.h"

void MVSetStreamVolume(float volume);
void MVSetStreamSpatialAudio(bool enabled);
/// Suspends or resumes audio output. Call with NO while the app leaves the
/// foreground so the render callback emits silence before the process can be
/// suspended or killed.
void MVSetStreamAudioActive(bool active);
