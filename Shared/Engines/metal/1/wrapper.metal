//  wrapper.metal — the `metal` engine's fragment function: dsScene at every pixel.
fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    DSContext ctx = ds_context(u, dsA0, dsA1, dsA2, dsA3, dsSmp);
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    return ds_finish(dsScene(uv, ctx).rgb, in.pos.xy);
}
