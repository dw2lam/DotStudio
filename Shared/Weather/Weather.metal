//  Weather.metal — the weather copies of Ocean Horizon and Shallows, in a compilation unit of
//  their own (fx_wx_ocean / fx_wx_shallows: Weather_fragment.h). It re-includes Shaders.metal for
//  its helpers and scene code, with the entry points there (fx_vertex, fx_fragment, the dither
//  kernels) compiled out; the linked metallib has one of each.
//
//  Why a unit of its own: the compiler's inlining decisions are made per unit, and with the
//  weather copies instantiated next to fx_fragment the live ocean's clear-sky copy (nature_oceanLive)
//  lost ~5% (11.1 → 11.7 ms at 5120×2880). Here they can't touch it.

#define DOTSTUDIO_WEATHER_UNIT 1
#include "../Shaders.metal"
#include "Weather_fragment.h"
