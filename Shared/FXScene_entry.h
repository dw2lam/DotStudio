//  FXScene_entry.h — one fragment function of its own for the effect id FX_SCENE_ID:
//
//      #define FX_SCENE_ID 43
//      #include "FXScene_entry.h"          // → fragment float4 fx_scene_43(FX_FRAGMENT_PARAMS)
//
//  The body is fx_fragment's (FXFragment_body.h) with the id a literal: the sources' branches and
//  the switch fold to that one case, so nothing else is compiled into it. Included from
//  SceneEntries.metal only (after Shaders.metal's helpers and scene code).

#define FX_SCENE_CAT2(a, b) a##b
#define FX_SCENE_CAT(a, b) FX_SCENE_CAT2(a, b)

fragment float4 FX_SCENE_CAT(fx_scene_, FX_SCENE_ID)(FX_FRAGMENT_PARAMS)
{
#define FX_EFFECT FX_SCENE_ID
#include "FXFragment_body.h"
#undef FX_EFFECT
}

#undef FX_SCENE_CAT
#undef FX_SCENE_CAT2
#undef FX_SCENE_ID
