//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "StreamView.h"

#import <QuartzCore/QuartzCore.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>

// Private libavformat API for writing the AV1 Codec Configuration Box
extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size,
                              int write_seq_header);

@implementation VideoDecoderRenderer {
    StreamView* _view;
    id<ConnectionCallbacks> _callbacks;
    float _streamAspectRatio;
    
    AVSampleBufferDisplayLayer* displayLayer;
    int videoFormat;
    int videoWidth;
    int videoHeight;
    int frameRate;
    
    NSMutableArray *parameterSetBuffers;
    NSData *masteringDisplayColorVolume;
    NSData *contentLightLevelInfo;
    CMVideoFormatDescriptionRef formatDesc;
    
    CADisplayLink* _displayLink;
    BOOL framePacing;
    CFTimeInterval lastFrameSubmitTime;
    CFTimeInterval lastIdrRequestTime;
    BOOL hdrEnabled;
    BOOL dynamicRangeHigh;
    BOOL externalFrameLogged;

}

- (void)reinitializeDisplayLayer
{
    CALayer *oldLayer = displayLayer;
    
    displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    displayLayer.backgroundColor = [UIColor blackColor].CGColor;

    // Start in standard range. The layer is switched to high only when the
    // actual format description (or the first HDR frame) proves HDR content is
    // present; the user's HDR preference alone is not enough.
    if (@available(visionOS 26.0, *)) {
        displayLayer.preferredDynamicRange = CADynamicRangeStandard;
        displayLayer.toneMapMode = CAToneMapModeAutomatic;
    }
    dynamicRangeHigh = NO;
    
    // Let AVFoundation do the aspect-fit. The layer fills the hosting view and
    // ResizeAspect creates the letterbox using the sample's real dimensions/PAR.
    // The window locks its aspect to the stream, so fill the layer exactly.
    // ResizeAspect keeps an aspect-fit render target that can be resampled
    // softly after the window is made smaller; the official window client
    // uses Resize for the same reason.
    displayLayer.videoGravity = AVLayerVideoGravityResize;
    [self layoutDisplayLayer];

    // Hide the layer until we get an IDR frame. This ensures we
    // can see the loading progress label as the stream is starting.
    displayLayer.hidden = YES;
    
    if (oldLayer != nil) {
        // Switch out the old display layer with the new one
        [_view.layer replaceSublayer:oldLayer with:displayLayer];
    }
    else {
        [_view.layer addSublayer:displayLayer];
    }
    
    if (formatDesc != nil) {
        CFRelease(formatDesc);
        formatDesc = nil;
    }
}

- (AVSampleBufferVideoRenderer*)activeVideoRenderer
{
    if (self.externalVideoRenderer != nil) {
        return self.externalVideoRenderer;
    }
    return displayLayer.sampleBufferRenderer;
}

- (BOOL)usesExternalRenderer
{
    return self.externalVideoRenderer != nil;
}

- (void)layoutDisplayLayer
{
    if (displayLayer == nil || _view == nil) {
        return;
    }
    CGRect bounds = _view.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        return;
    }

    // Keep the video rect from animating during a live window resize.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    displayLayer.frame = bounds;
    CGFloat scale = _view.window.traitCollection.displayScale;
    if (scale <= 0) {
        scale = _view.traitCollection.displayScale;
    }
    // Keep the video render surface at physical pixel density. With a scale
    // of 1 the layer downsamples to points and the compositor upsamples it
    // again, which is the blur seen after shrinking the window.
    scale = MAX(scale, 2.0);
    displayLayer.contentsScale = scale;
    [CATransaction commit];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"bounds"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self layoutDisplayLayer];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (BOOL)isHDRFormatDescription
{
    if (formatDesc == NULL) {
        return NO;
    }
    NSString *transfer = (__bridge NSString*)CMFormatDescriptionGetExtension(
        formatDesc, kCMFormatDescriptionExtension_TransferFunction);
    return [transfer isEqualToString:(__bridge NSString*)kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ] ||
           [transfer isEqualToString:(__bridge NSString*)kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG];
}

- (void)updateDynamicRange:(BOOL)high
{
    if (@available(visionOS 26.0, *)) {
        if (dynamicRangeHigh == high) {
            return;
        }
        dynamicRangeHigh = high;
        AVSampleBufferDisplayLayer *targetLayer = displayLayer;
        void (^apply)(void) = ^{
            CADynamicRange range = high ? CADynamicRangeHigh : CADynamicRangeStandard;
            targetLayer.toneMapMode = CAToneMapModeAutomatic;
            if (targetLayer.preferredDynamicRange != range) {
                targetLayer.preferredDynamicRange = range;
                Log(LOG_I, @"Display layer dynamic range: %@", high ? @"high (HDR)" : @"standard");
            }
        };
        // The range must be in place before the matching frame is enqueued;
        // otherwise the layer can show a stale, wrongly tone-mapped image.
        if ([NSThread isMainThread]) {
            apply();
        } else {
            dispatch_sync(dispatch_get_main_queue(), apply);
        }
    }
}

- (void)dealloc
{
    @try {
        [_view removeObserver:self forKeyPath:@"bounds"];
    } @catch (__unused NSException *exception) {
    }
}

- (NSString*)getColorDescription
{
    if (formatDesc == NULL) {
        return nil;
    }

    NSMutableArray *parts = [NSMutableArray array];

    NSNumber *bits = (__bridge NSNumber*)CMFormatDescriptionGetExtension(formatDesc, kCMFormatDescriptionExtension_BitsPerComponent);
    if (bits != nil) {
        [parts addObject:[NSString stringWithFormat:@"%d-bit", bits.intValue]];
    }

    NSString *primaries = (__bridge NSString*)CMFormatDescriptionGetExtension(formatDesc, kCMFormatDescriptionExtension_ColorPrimaries);
    if ([primaries isEqualToString:(__bridge NSString*)kCMFormatDescriptionColorPrimaries_ITU_R_2020]) {
        [parts addObject:@"BT.2020"];
    } else if ([primaries isEqualToString:(__bridge NSString*)kCMFormatDescriptionColorPrimaries_ITU_R_709_2]) {
        [parts addObject:@"BT.709"];
    } else if (primaries.length > 0) {
        [parts addObject:primaries];
    }

    NSString *transfer = (__bridge NSString*)CMFormatDescriptionGetExtension(formatDesc, kCMFormatDescriptionExtension_TransferFunction);
    if ([transfer isEqualToString:(__bridge NSString*)kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ]) {
        [parts addObject:@"PQ (HDR)"];
    } else if ([transfer isEqualToString:(__bridge NSString*)kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG]) {
        [parts addObject:@"HLG (HDR)"];
    } else if ([transfer isEqualToString:(__bridge NSString*)kCMFormatDescriptionTransferFunction_ITU_R_709_2]) {
        [parts addObject:@"BT.709"];
    } else if (transfer.length > 0) {
        [parts addObject:transfer];
    }

    return parts.count > 0 ? [parts componentsJoinedByString:@" · "] : nil;
}

- (id)initWithView:(StreamView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing
{
    self = [super init];

    _view = view;
    _callbacks = callbacks;
    _streamAspectRatio = aspectRatio;
    framePacing = useFramePacing;

    parameterSetBuffers = [[NSMutableArray alloc] init];

    [self reinitializeDisplayLayer];
    [_view addObserver:self forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:NULL];

    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate
{
    self->videoFormat = videoFormat;
    self->videoWidth = videoWidth;
    self->videoHeight = videoHeight;
    self->frameRate = frameRate;
    Log(LOG_I, @"Video setup format=0x%x %dx%d@%d", videoFormat, videoWidth, videoHeight, frameRate);
}

- (void)start
{
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(self->frameRate, self->frameRate, self->frameRate);
    }
    else {
        _displayLink.preferredFramesPerSecond = self->frameRate;
    }
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

// TODO: Refactor this
int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit);

- (void)displayLinkCallback:(CADisplayLink *)sender
{
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT du;
    
    while (LiPollNextVideoFrame(&handle, &du)) {
        int decodeResult = DrSubmitDecodeUnit(du);
        LiCompleteVideoFrame(handle, decodeResult);
        lastFrameSubmitTime = CACurrentMediaTime();

        if (framePacing) {
            // Calculate the actual display refresh rate
            double displayRefreshRate = 1 / (_displayLink.targetTimestamp - _displayLink.timestamp);

            // Only pace frames if the display refresh rate is >= 90% of our stream frame rate.
            // Battery saver, accessibility settings, or device thermals can cause the actual
            // refresh rate of the display to drop below the physical maximum.
            if (displayRefreshRate >= frameRate * 0.9f) {
                // Keep one pending frame to smooth out gaps due to
                // network jitter at the cost of 1 frame of latency
                if (LiGetPendingVideoFrames() == 1) {
                    break;
                }
            }
        }
    }


    // Mid-stream freeze recovery: if frames are queued but nothing has been
    // submitted for 450 ms, ask the host for an IDR frame (at most once per 2 s).
    CFTimeInterval now = CACurrentMediaTime();
    if (lastFrameSubmitTime != 0 && now - lastFrameSubmitTime > 0.45 &&
        LiGetPendingVideoFrames() > 0 && now - lastIdrRequestTime > 2.0) {
        Log(LOG_W, @"[Video] no frame submitted for %.0f ms with %d pending; requesting IDR",
            (now - lastFrameSubmitTime) * 1000.0, LiGetPendingVideoFrames());
        LiRequestIdrFrame();
        lastIdrRequestTime = now;
    }
}

- (void)stop
{
    [_displayLink invalidate];
}

#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4

- (void)updateAnnexBBufferForRange:(CMBlockBufferRef)frameBuffer dataBlock:(CMBlockBufferRef)dataBuffer offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(frameBuffer);
    
    // Append a 4 byte buffer to the frame block for the length prefix
    status = CMBlockBufferAppendMemoryBlock(frameBuffer, NULL,
                                            NAL_LENGTH_PREFIX_SIZE,
                                            kCFAllocatorDefault, NULL, 0,
                                            NAL_LENGTH_PREFIX_SIZE, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendMemoryBlock failed: %d", (int)status);
        return;
    }
    
    // Write the length prefix to the new buffer
    const int dataLength = nalLength - NALU_START_PREFIX_SIZE;
    const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
        (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
    status = CMBlockBufferReplaceDataBytes(lengthBytes, frameBuffer,
                                           oldOffset, NAL_LENGTH_PREFIX_SIZE);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
        return;
    }
    
    // Attach the data buffer to the frame buffer by reference
    status = CMBlockBufferAppendBufferReference(frameBuffer, dataBuffer, offset + NALU_START_PREFIX_SIZE, dataLength, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
        return;
    }
}

- (NSData*)getAv1CodecConfigurationBox:(NSData*)frameData  {
    AVIOContext* ioctx = NULL;
    int err;
    
    err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        Log(LOG_E, @"avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    // Submit the IDR frame to write the av1C blob
    err = ff_isom_write_av1c(ioctx, (uint8_t*)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        Log(LOG_E, @"ff_isom_write_av1c() failed: %d", err);
        // Fall-through to close and free buffer
    }
    
    // Close the dynbuf and get the underlying buffer back (which we must free)
    uint8_t* av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);
    
    Log(LOG_I, @"av1C block is %d bytes", av1cBufLen);
    
    // Only return data if ff_isom_write_av1c() was successful
    NSData* data = nil;
    if (err >= 0 && av1cBufLen > 0) {
        data = [NSData dataWithBytes:av1cBuf length:av1cBufLen];
    }
    else {
        data = nil;
    }
    
    av_free(av1cBuf);
    return data;
}

// Much of this logic comes from Chrome
- (CMVideoFormatDescriptionRef)createAV1FormatDescriptionForIDRFrame:(NSData*)frameData {
    NSMutableDictionary* extensions = [[NSMutableDictionary alloc] init];

    CodedBitstreamContext* cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_init() failed: %d", err);
        return nil;
    }
    
    AVPacket avPacket = {};
    avPacket.data = (uint8_t*)frameData.bytes;
    avPacket.size = (int)frameData.length;
    
    // Read the sequence header OBU
    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return nil;
    }
    
#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (__bridge NSString*)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");
    
    // We use the value for YUV without alpha, same as Chrome
    // https://developer.apple.com/library/archive/qa/qa1183/_index.html
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);
    
    CodedBitstreamAV1Context* bitstreamCtx = (CodedBitstreamAV1Context*)cbsCtx->priv_data;
    AV1RawSequenceHeader* seqHeader = bitstreamCtx->sequence_header;
    if (seqHeader == NULL) {
        Log(LOG_E, @"AV1 sequence header not found in IDR frame!");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return nil;
    }
    
    switch (seqHeader->color_config.color_primaries) {
        case 1: // CP_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
            break;
            
        case 6: // CP_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_SMPTE_C);
            break;
            
        case 9: // CP_BT_2020
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_2020);
            break;
            
        default:
            Log(LOG_W, @"Unsupported color_primaries value: %d", seqHeader->color_config.color_primaries);
            break;
    }
    
    switch (seqHeader->color_config.transfer_characteristics) {
        case 1: // TC_BT_709
        case 6: // TC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_709_2);
            break;
            
        case 7: // TC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_240M_1995);
            break;
            
        case 8: // TC_LINEAR
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_Linear);
            break;
            
        case 14: // TC_BT_2020_10_BIT
        case 15: // TC_BT_2020_12_BIT
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2020);
            break;
            
        case 16: // TC_SMPTE_2084
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
            break;
            
        case 17: // TC_HLG
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
            break;
            
        default:
            Log(LOG_W, @"Unsupported transfer_characteristics value: %d", seqHeader->color_config.transfer_characteristics);
            break;
    }
    
    switch (seqHeader->color_config.matrix_coefficients) {
        case 1: // MC_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
            break;
            
        case 6: // MC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
            break;
            
        case 7: // MC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995);
            break;
            
        case 9: // MC_BT_2020_NCL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020);
            break;
            
        default:
            Log(LOG_W, @"Unsupported matrix_coefficients value: %d", seqHeader->color_config.matrix_coefficients);
            break;
    }
    
    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));
    
    // Progressive content
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));
    
    switch (seqHeader->color_config.chroma_sample_position) {
        case 1: // CSP_VERTICAL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_Left);
            break;
            
        case 2: // CSP_COLOCATED
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_TopLeft);
            break;
            
        default:
            Log(LOG_W, @"Unsupported chroma_sample_position value: %d", seqHeader->color_config.chroma_sample_position);
            break;
    }
    
    if (contentLightLevelInfo) {
        SET_EXTENSION(kCMFormatDescriptionExtension_ContentLightLevelInfo, contentLightLevelInfo);
    }
    
    if (masteringDisplayColorVolume) {
        SET_EXTENSION(kCMFormatDescriptionExtension_MasteringDisplayColorVolume, masteringDisplayColorVolume);
    }
    
    // Referenced the VP9 code in Chrome that performs a similar function
    // https://source.chromium.org/chromium/chromium/src/+/main:media/gpu/mac/vt_config_util.mm;drc=977dc02c431b4979e34c7792bc3d646f649dacb4;l=155
    extensions[(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
    @{
        @"av1C" : [self getAv1CodecConfigurationBox:frameData],
    };
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);
    
#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION
    
    // AV1 doesn't have a special format description function like H.264 and HEVC have, so we just use the generic one
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width, bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions,
                                                     &formatDesc);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create AV1 format description: %d", (int)status);
        formatDesc = NULL;
    }
    
    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return formatDesc;
}

// This function must free data for bufferType == BUFFER_TYPE_PICDATA
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du
{
    OSStatus status;
    
    // Construct a new format description object each time we receive an IDR frame
    if (du->frameType == FRAME_TYPE_IDR) {
        if (bufferType != BUFFER_TYPE_PICDATA) {
            if (bufferType == BUFFER_TYPE_VPS || bufferType == BUFFER_TYPE_SPS || bufferType == BUFFER_TYPE_PPS) {
                // Add new parameter set into the parameter set array
                int startLen = data[2] == 0x01 ? 3 : 4;
                [parameterSetBuffers addObject:[NSData dataWithBytes:&data[startLen] length:length - startLen]];
            }
            
            // Data is NOT to be freed here. It's a direct usage of the caller's buffer.
            
            // No frame data to submit for these NALUs
            return DR_OK;
        }
        
        // Create the new format description when we get the first picture data buffer of an IDR frame.
        // This is the only way we know that there is no more CSD for this frame.
        //
        // NB: This logic depends on the fact that we submit all picture data in one buffer!
        
        // Free the old format description
        if (formatDesc != NULL) {
            CFRelease(formatDesc);
            formatDesc = NULL;
        }
        
        if (videoFormat & VIDEO_FORMAT_MASK_H264) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }
            
            Log(LOG_I, @"Constructing new H264 format description");
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         &formatDesc);
            if (status != noErr) {
                Log(LOG_E, @"Failed to create H264 format description: %d", (int)status);
                formatDesc = NULL;
            }
            
            // Free parameter set buffers after submission
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }
            
            Log(LOG_I, @"Constructing new HEVC format description");
            
            NSMutableDictionary* videoFormatParams = [[NSMutableDictionary alloc] init];
            
            if (contentLightLevelInfo) {
                [videoFormatParams setObject:contentLightLevelInfo forKey:(__bridge NSString*)kCMFormatDescriptionExtension_ContentLightLevelInfo];
            }
            
            if (masteringDisplayColorVolume) {
                [videoFormatParams setObject:masteringDisplayColorVolume forKey:(__bridge NSString*)kCMFormatDescriptionExtension_MasteringDisplayColorVolume];
            }

            // HEVC VUI parsing is not guaranteed to surface the colour tags on
            // every visionOS build. Tag HDR10 frames explicitly so the layer
            // and compositor see PQ/BT.2020 rather than an untagged 10-bit
            // buffer, which can be misinterpreted or tone-mapped incorrectly.
            if (du->hdrActive) {
                [videoFormatParams setObject:(__bridge NSString*)kCMFormatDescriptionColorPrimaries_ITU_R_2020
                                      forKey:(__bridge NSString*)kCMFormatDescriptionExtension_ColorPrimaries];
                [videoFormatParams setObject:(__bridge NSString*)kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                                      forKey:(__bridge NSString*)kCMFormatDescriptionExtension_TransferFunction];
                [videoFormatParams setObject:(__bridge NSString*)kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
                                      forKey:(__bridge NSString*)kCMFormatDescriptionExtension_YCbCrMatrix];
                [videoFormatParams setObject:@(NO)
                                      forKey:(__bridge NSString*)kCMFormatDescriptionExtension_FullRangeVideo];
                [videoFormatParams setObject:@(10)
                                      forKey:(__bridge NSString*)kCMFormatDescriptionExtension_BitsPerComponent];
            }
            
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         (__bridge CFDictionaryRef)videoFormatParams,
                                                                         &formatDesc);
            
            // A malformed MDCV/CLL extension must not leave the stream in an
            // endless DR_NEED_IDR loop. Retry without the optional metadata so
            // the video still decodes.
            if (status != noErr && videoFormatParams.count > 0) {
                Log(LOG_W, @"HEVC format description with HDR metadata failed (%d); retrying without metadata", (int)status);
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                             parameterSetCount,
                                                                             parameterSetPointers,
                                                                             parameterSetSizes,
                                                                             NAL_LENGTH_PREFIX_SIZE,
                                                                             NULL,
                                                                             &formatDesc);
            }
            
            if (status != noErr) {
                Log(LOG_E, @"Failed to create HEVC format description: %d", (int)status);
                formatDesc = NULL;
            }
            
            // Free parameter set buffers after submission
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_AV1) {
            NSData* fullFrameData = [NSData dataWithBytesNoCopy:data length:length freeWhenDone:NO];
            
            Log(LOG_I, @"Constructing new AV1 format description");
            formatDesc = [self createAV1FormatDescriptionForIDRFrame:fullFrameData];
        }
        else {
            // Unsupported codec!
            abort();
        }
    }
    
    if (formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return DR_NEED_IDR;
    }

    // Use the actual stream format, not the user's HDR preference, to choose
    // the layer's dynamic range. du->hdrActive is a fallback for formats whose
    // VUI transfer function is not exposed by VideoToolbox.
    BOOL hdrRange = [self isHDRFormatDescription] || (hdrEnabled && du->hdrActive);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc);
    Log(LOG_I, @"Video format: %dx%d hdrActive=%d hdrEnabled=%d formatHDR=%d range=%d",
        dimensions.width, dimensions.height,
        du->hdrActive ? 1 : 0, hdrEnabled ? 1 : 0,
        [self isHDRFormatDescription] ? 1 : 0, hdrRange ? 1 : 0);
    [self updateDynamicRange:hdrRange];
    
    // Check for previous decoder errors before doing anything. Use the
    // supported AVSampleBufferVideoRenderer surface; the queued-rendering
    // methods on AVSampleBufferDisplayLayer itself are deprecated on visionOS.
    // The frames belong to the standalone renderer owned by the window video
    // surface, so status/flush/enqueue must all use that renderer.
    AVSampleBufferVideoRenderer *videoRenderer = [self activeVideoRenderer];
    if (videoRenderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        Log(LOG_E, @"Display layer rendering failed: %@", videoRenderer.error);

        // Recreate the display layer on the main thread. submitDecodeBuffer can
        // run on the video decode thread, and swapping layers off-main while
        // the window is compositing HDR content can leave a stale/blurred image.
        free(data);
        void (^rebuildLayer)(void) = ^{
            if ([self usesExternalRenderer]) {
                // The standalone renderer is owned by the window video surface;
                // flush it and wait for a fresh IDR rather than replacing the
                // unused flat layer.
                [self.externalVideoRenderer flush];
            } else {
                [self reinitializeDisplayLayer];
            }
        };
        if ([NSThread isMainThread]) {
            rebuildLayer();
        } else {
            dispatch_sync(dispatch_get_main_queue(), rebuildLayer);
        }
        return DR_NEED_IDR;
    }
    if (videoRenderer.requiresFlushToResumeDecoding) {
        // The decoder lost permission to use its resources (for example while
        // the window is changing compositing state). Flush and wait for an IDR
        // instead of enqueueing into a queue that will not display.
        Log(LOG_W, @"Display layer requires flush; resetting decoder");
        [videoRenderer flush];
        free(data);
        return DR_NEED_IDR;
    }
    
    // Now we're decoding actual frame data here
    CMBlockBufferRef frameBlockBuffer;
    CMBlockBufferRef dataBlockBuffer;
    
    status = CMBlockBufferCreateWithMemoryBlock(NULL, data, length, kCFAllocatorDefault, NULL, 0, length, 0, &dataBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        free(data);
        return DR_NEED_IDR;
    }
    
    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced
    
    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &frameBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateEmpty failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        return DR_NEED_IDR;
    }
    
    // H.264 and HEVC formats require NAL prefix fixups from Annex B to length-delimited
    if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        int lastOffset = -1;
        for (int i = 0; i < length - NALU_START_PREFIX_SIZE; i++) {
            // Search for a NALU
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                // It's the start of a new NALU
                if (lastOffset != -1) {
                    // We've seen a start before this so enqueue that NALU
                    [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:i - lastOffset];
                }
                
                lastOffset = i;
            }
        }
        
        if (lastOffset != -1) {
            // Enqueue the remaining data
            [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:length - lastOffset];
        }
    }
    else {
        // For formats that require no length-changing fixups, just append a reference to the raw data block
        status = CMBlockBufferAppendBufferReference(frameBlockBuffer, dataBlockBuffer, 0, length, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
            return DR_NEED_IDR;
        }
    }
        
    CMSampleBufferRef sampleBuffer;
    
    CMSampleTimingInfo sampleTiming = {kCMTimeInvalid, CMTimeMake(du->presentationTimeUs, 1000000), kCMTimeInvalid};
    
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                  frameBlockBuffer,
                                  formatDesc, 1, 1,
                                  &sampleTiming, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        return DR_NEED_IDR;
    }

    // Enqueue the next frame through the supported renderer interface.
    if ([self usesExternalRenderer]) {
        // The standalone renderer has no movie timebase/preroll queue. Mark
        // each sample for immediate display, otherwise VideoMaterial can wait
        // for a presentation clock that never advances and stay black.
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef attachment =
                (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment,
                                 kCMSampleAttachmentKey_DisplayImmediately,
                                 kCFBooleanTrue);
        }
        if (!externalFrameLogged) {
            externalFrameLogged = YES;
            Log(LOG_I, @"VideoPlayerComponent renderer: first frame enqueued (%dx%d)",
                videoWidth, videoHeight);
        }
    }
    [videoRenderer enqueueSampleBuffer:sampleBuffer];
    
    if (du->frameType == FRAME_TYPE_IDR) {
        // Ensure the flat layer is visible now.
        if (![self usesExternalRenderer]) {
            self->displayLayer.hidden = NO;
        }
        
        // Tell our parent VC to hide the progress indicator
        [self->_callbacks videoContentShown];
    }
    
    // Dereference the buffers
    CFRelease(dataBlockBuffer);
    CFRelease(frameBlockBuffer);
    CFRelease(sampleBuffer);
    
    return DR_OK;
}

- (void)setHdrMode:(BOOL)enabled {
    BOOL modeChanged = (hdrEnabled != enabled);
    hdrEnabled = enabled;

    // Do not put the layer into high dynamic range just because the user asked
    // for HDR. Wait for the matching format description / HDR frame. When HDR
    // is turned off, standard range is safe immediately.
    if (!enabled) {
        [self updateDynamicRange:NO];
    }

    SS_HDR_METADATA hdrMetadata;
    
    BOOL hasMetadata = enabled && LiGetHdrMetadata(&hdrMetadata);
    BOOL metadataChanged = NO;
    
    if (hasMetadata && hdrMetadata.displayPrimaries[0].x != 0 && hdrMetadata.maxDisplayLuminance != 0) {
        // This data is all in big-endian
        struct {
          vector_ushort2 primaries[3];
          vector_ushort2 white_point;
          uint32_t luminance_max;
          uint32_t luminance_min;
        } __attribute__((packed, aligned(4))) mdcv;

        // mdcv is in GBR order while SS_HDR_METADATA is in RGB order
        mdcv.primaries[0].x = __builtin_bswap16(hdrMetadata.displayPrimaries[1].x);
        mdcv.primaries[0].y = __builtin_bswap16(hdrMetadata.displayPrimaries[1].y);
        mdcv.primaries[1].x = __builtin_bswap16(hdrMetadata.displayPrimaries[2].x);
        mdcv.primaries[1].y = __builtin_bswap16(hdrMetadata.displayPrimaries[2].y);
        mdcv.primaries[2].x = __builtin_bswap16(hdrMetadata.displayPrimaries[0].x);
        mdcv.primaries[2].y = __builtin_bswap16(hdrMetadata.displayPrimaries[0].y);

        mdcv.white_point.x = __builtin_bswap16(hdrMetadata.whitePoint.x);
        mdcv.white_point.y = __builtin_bswap16(hdrMetadata.whitePoint.y);

        // These luminance values are in 10000ths of a nit
        mdcv.luminance_max = __builtin_bswap32((uint32_t)hdrMetadata.maxDisplayLuminance * 10000);
        mdcv.luminance_min = __builtin_bswap32(hdrMetadata.minDisplayLuminance);

        NSData* newMdcv = [NSData dataWithBytes:&mdcv length:sizeof(mdcv)];
        if (masteringDisplayColorVolume == nil || ![newMdcv isEqualToData:masteringDisplayColorVolume]) {
            masteringDisplayColorVolume = newMdcv;
            metadataChanged = YES;
        }
    }
    else if (masteringDisplayColorVolume != nil) {
        masteringDisplayColorVolume = nil;
        metadataChanged = YES;
    }
    
    if (hasMetadata && hdrMetadata.maxContentLightLevel != 0 && hdrMetadata.maxFrameAverageLightLevel != 0) {
        // This data is all in big-endian
        struct {
            uint16_t max_content_light_level;
            uint16_t max_frame_average_light_level;
        } __attribute__((packed, aligned(2))) cll;

        cll.max_content_light_level = __builtin_bswap16(hdrMetadata.maxContentLightLevel);
        cll.max_frame_average_light_level = __builtin_bswap16(hdrMetadata.maxFrameAverageLightLevel);

        NSData* newCll = [NSData dataWithBytes:&cll length:sizeof(cll)];
        if (contentLightLevelInfo == nil || ![newCll isEqualToData:contentLightLevelInfo]) {
            contentLightLevelInfo = newCll;
            metadataChanged = YES;
        }
    }
    else if (contentLightLevelInfo != nil) {
        contentLightLevelInfo = nil;
        metadataChanged = YES;
    }
    
    // The dynamic range/format description changes require a clean decoder
    // hand-off. Flush the layer, hide the stale image, and wait for the next
    // IDR instead of leaving the old SDR/HDR frame on screen with a new range.
    if (modeChanged) {
        void (^resetLayer)(void) = ^{
            [[self activeVideoRenderer] flush];
            if (![self usesExternalRenderer]) {
                self->displayLayer.hidden = YES;
            }
        };
        // Hide/flush before asking for the IDR. If this ran asynchronously, an
        // IDR could be enqueued and unhide the layer first, then this block
        // would hide it again with no further frame to unhide it.
        if ([NSThread isMainThread]) {
            resetLayer();
        } else {
            dispatch_sync(dispatch_get_main_queue(), resetLayer);
        }
        LiRequestIdrFrame();
    } else if (metadataChanged) {
        // Metadata only: the next IDR rebuilds the format description, but the
        // current picture does not need to be flushed/hidden.
        LiRequestIdrFrame();
    }

    Log(LOG_I, @"HDR mode=%d changed=%d metadataChanged=%d metadata=%d",
        enabled ? 1 : 0, modeChanged ? 1 : 0, metadataChanged ? 1 : 0, hasMetadata ? 1 : 0);
}

@end
