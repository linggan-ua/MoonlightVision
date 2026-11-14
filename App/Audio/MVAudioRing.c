//
//  MVAudioRing.c
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Thin Swift-facing wrapper around the vendored ring buffer.
//

#include "MVAudioRing.h"
#include "TPCircularBuffer.h"

#include <stdlib.h>
#include <string.h>

struct MVAudioRing {
    TPCircularBuffer buffer;
};

MVAudioRing *MVAudioRingCreate(uint32_t capacityBytes) {
    if (capacityBytes == 0) {
        return NULL;
    }
    MVAudioRing *ring = calloc(1, sizeof(MVAudioRing));
    if (ring == NULL) {
        return NULL;
    }
    if (!_TPCircularBufferInit(&ring->buffer, capacityBytes, sizeof(TPCircularBuffer))) {
        free(ring);
        return NULL;
    }
    return ring;
}

void MVAudioRingDestroy(MVAudioRing *ring) {
    if (ring == NULL) {
        return;
    }
    TPCircularBufferCleanup(&ring->buffer);
    free(ring);
}

uint32_t MVAudioRingWrite(MVAudioRing *ring, const void *src, uint32_t bytes) {
    if (ring == NULL || src == NULL || bytes == 0) {
        return 0;
    }
    uint32_t space = 0;
    void *head = TPCircularBufferHead(&ring->buffer, &space);
    uint32_t amount = bytes < space ? bytes : space;
    if (amount > 0) {
        memcpy(head, src, amount);
        TPCircularBufferProduce(&ring->buffer, amount);
    }
    return amount;
}

uint32_t MVAudioRingRead(MVAudioRing *ring, void *dst, uint32_t bytes) {
    if (ring == NULL || dst == NULL || bytes == 0) {
        return 0;
    }
    uint32_t available = 0;
    void *tail = TPCircularBufferTail(&ring->buffer, &available);
    uint32_t amount = bytes < available ? bytes : available;
    if (amount > 0) {
        memcpy(dst, tail, amount);
        TPCircularBufferConsume(&ring->buffer, amount);
    }
    return amount;
}

uint32_t MVAudioRingAvailableBytes(const MVAudioRing *ring) {
    if (ring == NULL) {
        return 0;
    }
    uint32_t available = 0;
    TPCircularBufferTail((TPCircularBuffer *)&ring->buffer, &available);
    return available;
}

void MVAudioRingSkip(MVAudioRing *ring, uint32_t bytes) {
    if (ring == NULL || bytes == 0) {
        return;
    }
    uint32_t available = 0;
    TPCircularBufferTail(&ring->buffer, &available);
    uint32_t amount = bytes < available ? bytes : available;
    if (amount > 0) {
        TPCircularBufferConsume(&ring->buffer, amount);
    }
}
