"""The film look, baked in Blender's compositor (Blender 5 node-group compositor), plus a preview
grain pass for stills.

The spec's "look" block (all keys optional; omit the block for no post):

    "look": {
      "bloom":    {"strength": 0.08, "threshold": 3.0, "size": 0.55},           # soft neutral glare
      "halation": {"strength": 0.35, "threshold": 2.0, "size": 0.22,           # warm red-orange glow
                   "tint": [1.0, 0.32, 0.10]},                                  #   around bright edges
      "vignette": 0.22,                                                         # 0..1 corner darkening
      "grain":    {"amount": 0.018}                                             # PREVIEW ONLY (stills)
    }

Bloom and halation work on scene-linear light before the view transform, so they only touch real
highlights (sky through windows, chrome glints, sun patches); detail elsewhere stays crisp.
Thresholds are in scene-linear units BEFORE the view exposure: with an interior exposure of +1.8 EV
a threshold of 2-3 catches only the sky, glints and sun patches. Low thresholds turn big bright
windows into haze.
Grain is never baked into video: it bloats HEVC and the app adds it live at playback. For stills,
``grain_preview(png)`` writes ``<name>-grain.png`` so the final look can be judged.

    post.setup(scene, look)          # builds/replaces the compositor; look=None disables it
    post.enable(scene, on)           # toggle without rebuilding (e.g. a no-post comparison)
    post.grain_preview(src, dst, amount=0.03, seed=0)
"""
import bpy

DEFAULT = {
    "bloom": {"strength": 0.08, "threshold": 3.0, "size": 0.55},
    "halation": {"strength": 0.35, "threshold": 2.0, "size": 0.22, "tint": [1.0, 0.32, 0.10]},
    "vignette": 0.22,
    "grain": {"amount": 0.018},
}


def _glare(ng, src, kind, p, tint=(1, 1, 1)):
    g = ng.nodes.new("CompositorNodeGlare")
    g.inputs["Type"].default_value = "Bloom"
    g.inputs["Quality"].default_value = "High"
    g.inputs["Threshold"].default_value = p.get("threshold", 1.0)
    g.inputs["Smoothness"].default_value = p.get("smoothness", 0.3)
    g.inputs["Strength"].default_value = p.get("strength", 0.2)
    g.inputs["Size"].default_value = p.get("size", 0.5)
    g.inputs["Saturation"].default_value = p.get("saturation", 1.0)
    t = p.get("tint", tint)
    g.inputs["Tint"].default_value = (t[0], t[1], t[2], 1.0)
    ng.links.new(src, g.inputs["Image"])
    return g.outputs["Image"]


def setup(scene, look):
    if not look:
        scene.render.use_compositing = False
        return None
    ng = bpy.data.node_groups.new("FilmLook", "CompositorNodeTree")
    ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    rl = ng.nodes.new("CompositorNodeRLayers")
    out = ng.nodes.new("NodeGroupOutput")
    img = rl.outputs["Image"]
    if look.get("halation"):
        img = _glare(ng, img, "halation", look["halation"])
    if look.get("bloom"):
        img = _glare(ng, img, "bloom", look["bloom"])
    v = look.get("vignette", 0)
    if v:
        em = ng.nodes.new("CompositorNodeEllipseMask")
        em.inputs["Size"].default_value = (1.25, 1.25)
        bl = ng.nodes.new("CompositorNodeBlur")
        bl.inputs["Size"].default_value = (300, 300)
        ng.links.new(em.outputs["Mask"], bl.inputs["Image"])
        # factor: 1 - v * (1 - mask)
        m1 = ng.nodes.new("ShaderNodeMath")
        m1.operation = "MULTIPLY_ADD"
        m1.inputs[1].default_value = v
        m1.inputs[2].default_value = 1.0 - v
        ng.links.new(bl.outputs["Image"], m1.inputs[0])
        mx = ng.nodes.new("ShaderNodeMix")
        mx.data_type = "RGBA"
        mx.blend_type = "MULTIPLY"
        mx.inputs[0].default_value = 1.0
        ng.links.new(img, mx.inputs[6])
        ng.links.new(m1.outputs[0], mx.inputs[7])
        img = mx.outputs[2]
    ng.links.new(img, out.inputs[0])
    scene.compositing_node_group = ng
    scene.render.use_compositing = True
    return ng


def enable(scene, on):
    scene.render.use_compositing = bool(on) and scene.compositing_node_group is not None


def grain_preview(src, dst, amount=0.03, seed=0):
    """Adds film-like grain (luma-weighted, slightly soft, monochrome-ish) to a PNG -> dst. Preview
    only: the app adds grain live at playback, so it is never baked into the loop."""
    import numpy as np
    import os
    src, dst = os.path.abspath(src), os.path.abspath(dst)
    im = bpy.data.images.load(src, check_existing=False)
    im.colorspace_settings.name = "Non-Color"     # work on the encoded values as stored
    w, h = im.size
    px = np.empty(w * h * 4, np.float32)
    im.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    rng = np.random.default_rng(seed)
    n = rng.standard_normal((h, w)).astype(np.float32)
    # soften: average with a 1px-shifted copy (grain clumps, not per-pixel hiss)
    n = (n + np.roll(n, 1, 0) + np.roll(n, 1, 1) + np.roll(np.roll(n, 1, 0), 1, 1)) * 0.5
    chroma = rng.standard_normal((h, w, 3)).astype(np.float32) * 0.25
    luma = px[..., :3] @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    weight = (0.35 + 2.6 * luma * (1 - luma))[..., None]        # strongest in the midtones
    px[..., :3] = np.clip(px[..., :3] + amount * weight * (n[..., None] + chroma), 0, 1)
    out = bpy.data.images.new("grain", w, h, alpha=False)
    out.colorspace_settings.name = "Non-Color"
    out.pixels.foreach_set(px.ravel())
    out.filepath_raw = dst
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)
    bpy.data.images.remove(im)
    return dst
