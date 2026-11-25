//
//  MVAudioRing.c
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Thin Swift-facing wrapper around the vendored MVRingBuffer.
//

#include "MVAudioRing.h"
#include "MVRingBuffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct MVAudioRing {
    MVRingBuffer buffer;
    /// Written by the controller, read by the render thread. Plain atomics
    /// avoid taking a lock in the audio callback.
    atomic_bool suspended;
    /// Set when resuming; the render thread consumes it and drops whatever
    /// accumulated while suspended, so a delayed or hung producer can never
    /// leave stale audio queued for playback.
    atomic_bool flushPending;
};

MVAudioRing *MVAudioRingCreate(uint32_t capacityBytes) {
    if (capacityBytes == 0) {
        return NULL;
    }
    MVAudioRing *ring = calloc(1, sizeof(MVAudioRing));
    if (ring == NULL) {
        return NULL;
    }
    if (!MVRingBufferInit(&ring->buffer, capacityBytes, sizeof(MVRingBuffer))) {
        free(ring);
        return NULL;
    }
    return ring;
}

void MVAudioRingDestroy(MVAudioRing *ring) {
    if (ring == NULL) {
        return;
    }
    MVRingBufferCleanup(&ring->buffer);
    free(ring);
}

uint32_t MVAudioRingWrite(MVAudioRing *ring, const void *src, uint32_t bytes) {
    if (ring == NULL || src == NULL || bytes == 0) {
        return 0;
    }
    uint32_t space = 0;
    void *head = MVRingBufferHead(&ring->buffer, &space);
    uint32_t amount = bytes < space ? bytes : space;
    if (amount > 0) {
        memcpy(head, src, amount);
        MVRingBufferProduce(&ring->buffer, amount);
    }
    return amount;
}

uint32_t MVAudioRingRead(MVAudioRing *ring, void *dst, uint32_t bytes) {
    if (ring == NULL || dst == NULL || bytes == 0) {
        return 0;
    }
    if (atomic_load(&ring->suspended)) {
        return 0;
    }
    if (atomic_exchange(&ring->flushPending, false)) {
        // Resumed after being suspended: throw away everything that queued up
        // and let this callback output silence so priming restarts cleanly.
        uint32_t available = 0;
        MVRingBufferTail(&ring->buffer, &available);
        if (available > 0) {
            MVRingBufferConsume(&ring->buffer, available);
        }
        return 0;
    }
    uint32_t available = 0;
    void *tail = MVRingBufferTail(&ring->buffer, &available);
    uint32_t amount = bytes < available ? bytes : available;
    if (amount > 0) {
        memcpy(dst, tail, amount);
        MVRingBufferConsume(&ring->buffer, amount);
    }
    return amount;
}

uint32_t MVAudioRingAvailableBytes(const MVAudioRing *ring) {
    if (ring == NULL) {
        return 0;
    }
    MVAudioRing *mutable = (MVAudioRing *)ring;
    if (atomic_load(&mutable->suspended)) {
        return 0;
    }
    uint32_t available = 0;
    MVRingBufferTail(&mutable->buffer, &available);
    return available;
}

void MVAudioRingSkip(MVAudioRing *ring, uint32_t bytes) {
    if (ring == NULL || bytes == 0) {
        return;
    }
    uint32_t available = 0;
    MVRingBufferTail(&ring->buffer, &available);
    uint32_t amount = bytes < available ? bytes : available;
    if (amount > 0) {
        MVRingBufferConsume(&ring->buffer, amount);
    }
}

void MVAudioRingSetSuspended(MVAudioRing *ring, bool suspended) {
    if (ring == NULL) {
        return;
    }
    if (!suspended) {
        atomic_store(&ring->flushPending, true);
    }
    atomic_store(&ring->suspended, suspended);
}
