//  SceneEntries.metal — the effects and scenes with a fragment function of their own,
//  fx_scene_<id> (FXScene_entry.h: fx_fragment's body with the id a literal, so each function
//  holds just that case), in a compilation unit of their own. It re-includes Shaders.metal for
//  its helpers and scene code, with the entry points there compiled out (like Weather.metal).
//
//  Why: the über-shader is allocated registers for its heaviest case, which costs every other
//  case occupancy. Measured at 5120×2880 (tools/gallery --pipebench), every id drew faster in
//  its own function: the scenes 10–70 % (Word Clock 7.4 → 2.2 ms, Universe 10.3 → 4.4, Aurora
//  13.0 → 8.9), the one-tap post effects and the source / crossfade passes ~0.6 → ~0.2 ms a
//  pass. So every id but the two below has one; fx_fragment remains the stand-in until a
//  pipeline is built (or if it fails).
//  ScenePipelines (FXPipelines.swift) lists the same ids: keep the two lists the same, and
//  re-measure a scene whose code changes much (drop it from both if it is no longer faster).
//  Ocean Horizon (59) and Shallows (67) have theirs in Weather_fragment.h (WeatherLink).

#pragma clang diagnostic ignored "-Wunused-variable"   // (each entry re-reads every case)
#define DOTSTUDIO_SCENE_UNIT 1
#include "Shaders.metal"

#define FX_SCENE_ID 0
#include "FXScene_entry.h"
#define FX_SCENE_ID 1
#include "FXScene_entry.h"
#define FX_SCENE_ID 2
#include "FXScene_entry.h"
#define FX_SCENE_ID 3
#include "FXScene_entry.h"
#define FX_SCENE_ID 4
#include "FXScene_entry.h"
#define FX_SCENE_ID 5
#include "FXScene_entry.h"
#define FX_SCENE_ID 6
#include "FXScene_entry.h"
#define FX_SCENE_ID 7
#include "FXScene_entry.h"
#define FX_SCENE_ID 8
#include "FXScene_entry.h"
#define FX_SCENE_ID 9
#include "FXScene_entry.h"
#define FX_SCENE_ID 10
#include "FXScene_entry.h"
#define FX_SCENE_ID 11
#include "FXScene_entry.h"
#define FX_SCENE_ID 12
#include "FXScene_entry.h"
#define FX_SCENE_ID 13
#include "FXScene_entry.h"
#define FX_SCENE_ID 14
#include "FXScene_entry.h"
#define FX_SCENE_ID 15
#include "FXScene_entry.h"
#define FX_SCENE_ID 16
#include "FXScene_entry.h"
#define FX_SCENE_ID 17
#include "FXScene_entry.h"
#define FX_SCENE_ID 18
#include "FXScene_entry.h"
#define FX_SCENE_ID 19
#include "FXScene_entry.h"
#define FX_SCENE_ID 20
#include "FXScene_entry.h"
#define FX_SCENE_ID 21
#include "FXScene_entry.h"
#define FX_SCENE_ID 22
#include "FXScene_entry.h"
#define FX_SCENE_ID 23
#include "FXScene_entry.h"
#define FX_SCENE_ID 24
#include "FXScene_entry.h"
#define FX_SCENE_ID 25
#include "FXScene_entry.h"
#define FX_SCENE_ID 26
#include "FXScene_entry.h"
#define FX_SCENE_ID 27
#include "FXScene_entry.h"
#define FX_SCENE_ID 28
#include "FXScene_entry.h"
#define FX_SCENE_ID 29
#include "FXScene_entry.h"
#define FX_SCENE_ID 30
#include "FXScene_entry.h"
#define FX_SCENE_ID 31
#include "FXScene_entry.h"
#define FX_SCENE_ID 32
#include "FXScene_entry.h"
#define FX_SCENE_ID 33
#include "FXScene_entry.h"
#define FX_SCENE_ID 34
#include "FXScene_entry.h"
#define FX_SCENE_ID 35
#include "FXScene_entry.h"
#define FX_SCENE_ID 36
#include "FXScene_entry.h"
#define FX_SCENE_ID 37
#include "FXScene_entry.h"
#define FX_SCENE_ID 38
#include "FXScene_entry.h"
#define FX_SCENE_ID 39
#include "FXScene_entry.h"
#define FX_SCENE_ID 40
#include "FXScene_entry.h"
#define FX_SCENE_ID 41
#include "FXScene_entry.h"
#define FX_SCENE_ID 42
#include "FXScene_entry.h"
#define FX_SCENE_ID 43
#include "FXScene_entry.h"
#define FX_SCENE_ID 44
#include "FXScene_entry.h"
#define FX_SCENE_ID 45
#include "FXScene_entry.h"
#define FX_SCENE_ID 46
#include "FXScene_entry.h"
#define FX_SCENE_ID 47
#include "FXScene_entry.h"
#define FX_SCENE_ID 48
#include "FXScene_entry.h"
#define FX_SCENE_ID 49
#include "FXScene_entry.h"
#define FX_SCENE_ID 50
#include "FXScene_entry.h"
#define FX_SCENE_ID 51
#include "FXScene_entry.h"
#define FX_SCENE_ID 52
#include "FXScene_entry.h"
#define FX_SCENE_ID 53
#include "FXScene_entry.h"
#define FX_SCENE_ID 54
#include "FXScene_entry.h"
#define FX_SCENE_ID 55
#include "FXScene_entry.h"
#define FX_SCENE_ID 56
#include "FXScene_entry.h"
#define FX_SCENE_ID 57
#include "FXScene_entry.h"
#define FX_SCENE_ID 58
#include "FXScene_entry.h"
#define FX_SCENE_ID 60
#include "FXScene_entry.h"
#define FX_SCENE_ID 61
#include "FXScene_entry.h"
#define FX_SCENE_ID 62
#include "FXScene_entry.h"
#define FX_SCENE_ID 63
#include "FXScene_entry.h"
#define FX_SCENE_ID 64
#include "FXScene_entry.h"
#define FX_SCENE_ID 65
#include "FXScene_entry.h"
#define FX_SCENE_ID 66
#include "FXScene_entry.h"
#define FX_SCENE_ID 68
#include "FXScene_entry.h"
#define FX_SCENE_ID 69
#include "FXScene_entry.h"
#define FX_SCENE_ID 70
#include "FXScene_entry.h"
#define FX_SCENE_ID 71
#include "FXScene_entry.h"
#define FX_SCENE_ID 72
#include "FXScene_entry.h"
#define FX_SCENE_ID 74
#include "FXScene_entry.h"
#define FX_SCENE_ID 75
#include "FXScene_entry.h"
#define FX_SCENE_ID 76
#include "FXScene_entry.h"
#define FX_SCENE_ID 77
#include "FXScene_entry.h"
#define FX_SCENE_ID 79
#include "FXScene_entry.h"
