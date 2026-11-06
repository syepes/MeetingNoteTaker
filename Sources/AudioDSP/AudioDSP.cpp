#include "AudioDSP.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>
#include <algorithm>
struct MNTRing { MNTPacket packets[128]; std::atomic<uint32_t> read{0}, write{0}; std::atomic<uint64_t> dropped{0}; std::atomic<bool> muted{false}; std::atomic<uint64_t> accepted{0}; std::atomic<double> first{-1}, last{-1}, pauseStart{-1}, pauseEnd{-1}; };
MNTRing *mnt_ring_create(void) { return new MNTRing; }
void mnt_ring_destroy(MNTRing *r) { delete r; }
void mnt_ring_reset(MNTRing *r) { r->read=0; r->write=0; r->dropped=0; r->accepted=0; r->first=-1; r->last=-1; r->pauseStart=-1; r->pauseEnd=-1; }
bool mnt_ring_push(MNTRing *r, const float *const *channels, uint32_t n, uint32_t stride, uint32_t frames, double rate, double time, bool muted) {
    if (!std::isfinite(time) || !std::isfinite(rate) || rate <= 0 || !frames) { r->dropped++; return false; }
    uint32_t w = r->write.load(std::memory_order_relaxed), next = (w+1)%128;
    if (next == r->read.load(std::memory_order_acquire) || frames > MNT_MAX_FRAMES || !n) { r->dropped++; return false; }
    if (!channels || !stride) { r->dropped++; return false; }
    for(uint32_t c=0;c<n;c++) if(!channels[c]) { r->dropped++; return false; }
    auto &p=r->packets[w]; p.time=time; p.rate=rate; p.count=frames; muted = muted || r->muted.load(std::memory_order_relaxed);
    double pauseStart=r->pauseStart.load(), pauseEnd=r->pauseEnd.load();
    const double lastTime = time + (frames-1)/rate;
    const bool overlaps = pauseStart>=0 && lastTime>=pauseStart && (pauseEnd<0 || time<pauseEnd);
    const bool fullyPaused = overlaps && time>=pauseStart && (pauseEnd<0 || lastTime<pauseEnd);
    if(muted || fullyPaused) std::memset(p.samples, 0, frames*sizeof(float));
    else if(!overlaps && n==1 && stride==1) std::memcpy(p.samples, channels[0], frames*sizeof(float));
    else if(!overlaps) {
        for(uint32_t i=0;i<frames;i++){ float x=0; for(uint32_t c=0;c<n;c++) x+=channels[c][i*stride]; p.samples[i]=x/n; }
    } else {
    for(uint32_t i=0;i<frames;i++){ double t=time+i/rate; bool paused=pauseStart>=0 && t>=pauseStart && (pauseEnd<0 || t<pauseEnd); float x=0; if(!muted && !paused) for(uint32_t c=0;c<n;c++) x+=channels[c][i*stride]; p.samples[i]=x/n; }
    }
    if(r->accepted.load()==0) r->first.store(time);
    r->accepted.fetch_add(frames);
    r->last.store(time + frames/rate, std::memory_order_release);
    r->write.store(next,std::memory_order_release); return true;
}
bool mnt_ring_pop(MNTRing *r, MNTPacket *p) {
    uint32_t v=r->read.load(std::memory_order_relaxed);
    if(v==r->write.load(std::memory_order_acquire)) return false;
    std::memcpy(p,&r->packets[v],offsetof(MNTPacket,samples)+r->packets[v].count*sizeof(float));
    r->read.store((v+1)%128,std::memory_order_release); return true;
}
uint64_t mnt_ring_dropped(MNTRing *r){ return r->dropped.load(); }
void mnt_ring_set_muted(MNTRing *r, bool muted) { r->muted.store(muted); }
bool mnt_ring_is_muted(MNTRing *r) { return r->muted.load(); }
const float *mnt_packet_samples(const MNTPacket *packet) { return packet->samples; }
float mnt_reduce_echo(float *mic,const float *ref,uint32_t count,uint32_t rate){
    if(count<rate/2) return 0;
    // Find a delayed linear echo path. Never gate or delete microphone speech.
    int maxLag=std::min<int>(rate*0.3,count/4), best=0; double bestCorr=0;
    for(int lag=0;lag<=maxLag;lag+=8){
        double xy=0,xx=1e-12,yy=1e-12;
        for(uint32_t i=maxLag;i<count;i+=16){double x=ref[i-lag],y=mic[i];xy+=x*y;xx+=x*x;yy+=y*y;}
        double corr=xy/std::sqrt(xx*yy); if(corr>bestCorr){bestCorr=corr;best=lag;}
    }
    if(bestCorr<0.55) return 0;
    double xy=0,xx=1e-12;
    for(uint32_t i=maxLag;i<count;i++){xy+=mic[i]*ref[i-best];xx+=ref[i-best]*ref[i-best];}
    float gain=std::clamp(float(xy/xx),0.f,1.5f);
    // Cross-correlation subtraction preserves independent/double-talk speech;
    // a short ramp avoids edges when processing independent chunks.
    for(uint32_t i=best;i<count;i++){
        float ramp=std::min(1.f,std::min(float(i-best),float(count-i-1))/(rate*0.02f));
        mic[i]-=0.85f*gain*ramp*ref[i-best];
    }
    return gain;
}

double mnt_ring_last_time(MNTRing *r) { return r->last.load(); }
void mnt_ring_pause(MNTRing *r, double time) { r->pauseEnd.store(-1); r->pauseStart.store(time); }
void mnt_ring_resume(MNTRing *r, double time) { r->pauseEnd.store(time); }

uint64_t mnt_ring_accepted_frames(MNTRing *r) { return r->accepted.load(); }
double mnt_ring_first_time(MNTRing *r) { return r->first.load(); }
