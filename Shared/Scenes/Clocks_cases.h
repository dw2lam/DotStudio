//  Clocks_cases.h — switch cases for the Clocks pack (shader ids 50–53). Included
//  INSIDE fx_fragment's switch(u.effect): write `case NN: { …; return float4(col, 1.0); }`.
//  In scope: uv, res, px, t (seconds), u (FXUniforms incl. u.clock / u.date), src, glyphs,
//  samp, base, L. Scenes ignore src/base.
