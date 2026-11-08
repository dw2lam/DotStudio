//  Retro_cases.h — switch cases for the Retro pack (shader ids 62–65). Included
//  INSIDE fx_fragment's switch(u.effect): write `case NN: { …; return float4(col, 1.0); }`.
//  In scope: uv, res, px, t (seconds), u (FXUniforms incl. u.clock / u.date), src, glyphs,
//  samp, base, L. Scenes ignore src/base.
