//  wrapper.metal — the `shadertoy` engine's fragment function: mainImage at every pixel, with
//  Shadertoy's uniforms filled from DotStudio's context. fragCoord is in pixels from the bottom
//  left (pixel centres at .5), as on Shadertoy.
fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    DSShadertoy _st;
    _st.ctx = ds_context(u, dsA0, dsA1, dsA2, dsA3, dsSmp);
    _st.st_iResolution = float3(_st.ctx.res, 1.0);
    _st.st_iTime = _st.ctx.t;
    _st.st_iTimeDelta = 1.0 / 60.0;
    _st.st_iFrame = int(_st.ctx.t * 60.0);
    _st.st_iFrameRate = 60.0;
    _st.st_iMouse = float4(0.0);
    _st.st_iDate = float4(float(_st.ctx.date.year), float(_st.ctx.date.month - 1), float(_st.ctx.date.day), _st.ctx.clock);
    _st.st_iSampleRate = 44100.0;
    float2 fragCoord = float2(in.pos.x, _st.ctx.res.y - in.pos.y);
    float4 fragColor = float4(0.0, 0.0, 0.0, 1.0);
    mainImage(_st, fragColor, fragCoord);
    return ds_finish(fragColor.rgb, in.pos.xy);
}
