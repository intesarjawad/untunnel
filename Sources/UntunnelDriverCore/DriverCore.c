#include "UntunnelDriverCore.h"

#include <stddef.h>

static int64_t ring_index(const untunnel_ring *ring, int64_t sample_time) {
    int64_t index = sample_time % ring->capacity_frames;
    return index < 0 ? index + ring->capacity_frames : index;
}

void untunnel_ring_init(untunnel_ring *ring, float *storage, int64_t capacity_frames) {
    ring->samples = storage;
    ring->capacity_frames = capacity_frames;
    for (int64_t index = 0; index < capacity_frames * UNTUNNEL_RING_CHANNELS; index++) {
        storage[index] = 0;
    }
    untunnel_ring_clear(ring);
}

void untunnel_ring_clear(untunnel_ring *ring) {
    __atomic_store_n(&ring->written_end, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&ring->written_start, 0, __ATOMIC_RELEASE);
}

void untunnel_ring_write(
    untunnel_ring *ring,
    int64_t sample_time,
    const float *frames,
    uint32_t frame_count,
    uint32_t channels) {
    int64_t start = __atomic_load_n(&ring->written_start, __ATOMIC_ACQUIRE);
    int64_t end = __atomic_load_n(&ring->written_end, __ATOMIC_ACQUIRE);
    bool empty = end <= start;

    if (empty) {
        start = sample_time;
        end = sample_time;
    } else if (sample_time > end) {
        int64_t gap = sample_time - end;
        if (gap > ring->capacity_frames) {
            gap = ring->capacity_frames;
        }
        for (int64_t offset = 0; offset < gap; offset++) {
            float *frame = ring->samples + ring_index(ring, end + offset) * UNTUNNEL_RING_CHANNELS;
            frame[0] = 0;
            frame[1] = 0;
        }
    } else if (sample_time < start) {
        start = sample_time;
    }

    for (uint32_t offset = 0; offset < frame_count; offset++) {
        float *frame = ring->samples + ring_index(ring, sample_time + offset) * UNTUNNEL_RING_CHANNELS;
        const float *source = frames + (size_t)offset * channels;
        frame[0] = source[0];
        frame[1] = channels > 1 ? source[1] : source[0];
    }

    int64_t written_end = sample_time + frame_count;
    if (written_end > end) {
        end = written_end;
    }
    __atomic_store_n(&ring->written_start, start, __ATOMIC_RELEASE);
    __atomic_store_n(&ring->written_end, end, __ATOMIC_RELEASE);
}

void untunnel_ring_read(
    untunnel_ring *ring,
    int64_t sample_time,
    float *frames,
    uint32_t frame_count,
    uint32_t channels) {
    int64_t start = __atomic_load_n(&ring->written_start, __ATOMIC_ACQUIRE);
    int64_t end = __atomic_load_n(&ring->written_end, __ATOMIC_ACQUIRE);
    int64_t oldest = end - ring->capacity_frames;
    if (oldest < start) {
        oldest = start;
    }

    for (uint32_t offset = 0; offset < frame_count; offset++) {
        float *target = frames + (size_t)offset * channels;
        int64_t time = sample_time + offset;
        if (end <= start || time < oldest || time >= end) {
            for (uint32_t channel = 0; channel < channels; channel++) {
                target[channel] = 0;
            }
            continue;
        }
        const float *frame = ring->samples + ring_index(ring, time) * UNTUNNEL_RING_CHANNELS;
        if (channels == 1) {
            target[0] = (frame[0] + frame[1]) * 0.5f;
        } else {
            target[0] = frame[0];
            target[1] = frame[1];
            for (uint32_t channel = 2; channel < channels; channel++) {
                target[channel] = 0;
            }
        }
    }
}

void untunnel_clock_init(untunnel_clock *clock, double host_ticks_per_frame, uint64_t period_frames) {
    clock->anchor_host_time = 0;
    clock->host_ticks_per_frame = host_ticks_per_frame;
    clock->period_frames = period_frames;
}

void untunnel_clock_start(untunnel_clock *clock, uint64_t now_host_time) {
    clock->anchor_host_time = now_host_time;
}

void untunnel_clock_zero_time_stamp(
    const untunnel_clock *clock,
    uint64_t now_host_time,
    double *sample_time,
    uint64_t *host_time) {
    double ticks_per_period = clock->host_ticks_per_frame * (double)clock->period_frames;
    uint64_t elapsed =
        now_host_time > clock->anchor_host_time ? now_host_time - clock->anchor_host_time : 0;
    uint64_t periods = (uint64_t)((double)elapsed / ticks_per_period);
    *sample_time = (double)(periods * clock->period_frames);
    *host_time = clock->anchor_host_time + (uint64_t)((double)periods * ticks_per_period);
}

void untunnel_liveness_init(untunnel_liveness *liveness, untunnel_liveness_mode mode, uint64_t timeout_ns) {
    liveness->mode = mode;
    liveness->timeout_ns = timeout_ns;
    liveness->last_write_ns = 0;
    liveness->feed_clients = 0;
    liveness->armed = false;
    liveness->visible = true;
}

void untunnel_liveness_note_write(untunnel_liveness *liveness, uint64_t now_ns) {
    __atomic_store_n(&liveness->last_write_ns, now_ns, __ATOMIC_RELEASE);
}

void untunnel_liveness_client_added(untunnel_liveness *liveness) {
    liveness->feed_clients++;
    if (liveness->mode == UNTUNNEL_LIVENESS_CLIENTS) {
        liveness->armed = true;
    }
}

void untunnel_liveness_client_removed(untunnel_liveness *liveness) {
    if (liveness->feed_clients > 0) {
        liveness->feed_clients--;
    }
}

bool untunnel_liveness_update(untunnel_liveness *liveness, uint64_t now_ns) {
    bool visible;
    if (liveness->mode == UNTUNNEL_LIVENESS_CLIENTS) {
        visible = !liveness->armed || liveness->feed_clients > 0;
    } else {
        uint64_t last = __atomic_load_n(&liveness->last_write_ns, __ATOMIC_ACQUIRE);
        if (last != 0) {
            liveness->armed = true;
        }
        visible = !liveness->armed || now_ns < last || now_ns - last < liveness->timeout_ns;
    }
    bool changed = visible != liveness->visible;
    liveness->visible = visible;
    return changed;
}
