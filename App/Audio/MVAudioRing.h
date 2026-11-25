//
//  MVAudioRing.h
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Thin Swift-facing wrapper around MVRingBuffer (single producer, single
//  consumer, lock-free). See CREDITS.md for the attribution.
//

#ifndef MVAudioRing_h
#define MVAudioRing_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MVAudioRing MVAudioRing;

MVAudioRing *MVAudioRingCreate(uint32_t capacityBytes);
void MVAudioRingDestroy(MVAudioRing *ring);
uint32_t MVAudioRingWrite(MVAudioRing *ring, const void *src, uint32_t bytes);
/// Consumer side, render thread. Returns 0 and outputs nothing while
/// suspended, and drops all buffered audio on the first call after resuming.
uint32_t MVAudioRingRead(MVAudioRing *ring, void *dst, uint32_t bytes);
uint32_t MVAudioRingAvailableBytes(const MVAudioRing *ring);
void MVAudioRingSkip(MVAudioRing *ring, uint32_t bytes);
/// Suspends or resumes the consumer. Set from any thread; resuming marks the
/// buffer to be flushed by the render thread itself on its next call, so no
/// second thread ever touches the read index.
void MVAudioRingSetSuspended(MVAudioRing *ring, bool suspended);

#ifdef __cplusplus
}
#endif

#endif /* MVAudioRing_h */
