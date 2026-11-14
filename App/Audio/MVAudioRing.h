//
//  MVAudioRing.h
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Thin Swift-facing wrapper around ring buffer (single producer,
//  single consumer, lock-free). ring buffer is the vendored official
//  Ring implementation (zlib license).
//

#ifndef MVAudioRing_h
#define MVAudioRing_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MVAudioRing MVAudioRing;

MVAudioRing *MVAudioRingCreate(uint32_t capacityBytes);
void MVAudioRingDestroy(MVAudioRing *ring);
uint32_t MVAudioRingWrite(MVAudioRing *ring, const void *src, uint32_t bytes);
uint32_t MVAudioRingRead(MVAudioRing *ring, void *dst, uint32_t bytes);
uint32_t MVAudioRingAvailableBytes(const MVAudioRing *ring);
void MVAudioRingSkip(MVAudioRing *ring, uint32_t bytes);

#ifdef __cplusplus
}
#endif

#endif /* MVAudioRing_h */
