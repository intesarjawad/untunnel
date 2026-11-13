#ifndef UNTUNNEL_DRIVER_CORE_H
#define UNTUNNEL_DRIVER_CORE_H

#include <stdbool.h>
#include <stdint.h>

/// The logic of the audio plug-in that does not need coreaudiod, kept apart so it can be tested.
///
/// The plug-in publishes two devices on one clock: a hidden output the app writes into and a
/// visible microphone other apps read. Both index one ring by the clock's sample time, so a
/// frame the app writes for time T is the frame a reader asks for at time T.

/// Channels stored per ring frame; a mono writer fills both and a mono reader averages them.
#define UNTUNNEL_RING_CHANNELS 2

typedef struct {
    float *samples;
    int64_t capacity_frames;
    int64_t written_start;
    int64_t written_end;
} untunnel_ring;

/// Uses `storage`, which must hold `capacity_frames * UNTUNNEL_RING_CHANNELS` floats.
void untunnel_ring_init(untunnel_ring *ring, float *storage, int64_t capacity_frames);

/// Forgets everything written, so readers get silence until the next write.
void untunnel_ring_clear(untunnel_ring *ring);

/// Stores `frame_count` frames of `channels` (1 or 2) interleaved samples at `sample_time`.
///
/// A write that starts after the last one zeroes the gap, so a reader never hears stale frames.
void untunnel_ring_write(
    untunnel_ring *ring,
    int64_t sample_time,
    const float *frames,
    uint32_t frame_count,
    uint32_t channels);

/// Reads `frame_count` frames at `sample_time`, with silence where nothing current was written.
void untunnel_ring_read(
    untunnel_ring *ring,
    int64_t sample_time,
    float *frames,
    uint32_t frame_count,
    uint32_t channels);

/// The shared clock: one zero time stamp per period, anchored when the first device starts.
typedef struct {
    uint64_t anchor_host_time;
    double host_ticks_per_frame;
    uint64_t period_frames;
} untunnel_clock;

void untunnel_clock_init(untunnel_clock *clock, double host_ticks_per_frame, uint64_t period_frames);

void untunnel_clock_start(untunnel_clock *clock, uint64_t now_host_time);

/// The latest period boundary at or before `now_host_time`.
void untunnel_clock_zero_time_stamp(
    const untunnel_clock *clock,
    uint64_t now_host_time,
    double *sample_time,
    uint64_t *host_time);

/// What takes the microphone away when the app is gone.
typedef enum {
    /// The microphone disappears once no write has reached the feed for the timeout.
    UNTUNNEL_LIVENESS_WRITES = 0,
    /// The microphone disappears when the last client leaves the feed device.
    UNTUNNEL_LIVENESS_CLIENTS = 1,
} untunnel_liveness_mode;

/// Decides whether the microphone is listed.
///
/// Until the app has written once (or attached once, by client) the microphone stays listed,
/// so an installed plug-in shows its device before the app first runs.
typedef struct {
    untunnel_liveness_mode mode;
    uint64_t timeout_ns;
    uint64_t last_write_ns;
    uint32_t feed_clients;
    bool armed;
    bool visible;
} untunnel_liveness;

void untunnel_liveness_init(untunnel_liveness *liveness, untunnel_liveness_mode mode, uint64_t timeout_ns);

/// Records a write; safe on the IO thread because it is one atomic store.
void untunnel_liveness_note_write(untunnel_liveness *liveness, uint64_t now_ns);

void untunnel_liveness_client_added(untunnel_liveness *liveness);

void untunnel_liveness_client_removed(untunnel_liveness *liveness);

/// Recomputes `visible` and returns whether it changed.
bool untunnel_liveness_update(untunnel_liveness *liveness, uint64_t now_ns);

#endif
