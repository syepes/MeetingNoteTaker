#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
#define MNT_MAX_FRAMES 8192
typedef struct { double time; double rate; uint32_t count; float samples[MNT_MAX_FRAMES]; } MNTPacket;
typedef struct MNTRing MNTRing;
MNTRing *mnt_ring_create(void);
void mnt_ring_destroy(MNTRing *ring);
void mnt_ring_reset(MNTRing *ring);
bool mnt_ring_push(MNTRing *ring, const float *const *channels, uint32_t channelCount, uint32_t stride, uint32_t frames, double rate, double time, bool muted);
bool mnt_ring_pop(MNTRing *ring, MNTPacket *packet);
const float *mnt_packet_samples(const MNTPacket *packet);
uint64_t mnt_ring_dropped(MNTRing *ring);
void mnt_ring_set_muted(MNTRing *ring, bool muted);
bool mnt_ring_is_muted(MNTRing *ring);
double mnt_ring_last_time(MNTRing *ring);
void mnt_ring_pause(MNTRing *ring, double time);
void mnt_ring_resume(MNTRing *ring, double time);
// Conservative offline reference cancellation. Returns estimated echo gain.
float mnt_reduce_echo(float *mic, const float *reference, uint32_t count, uint32_t rate);
#ifdef __cplusplus
}
#endif
