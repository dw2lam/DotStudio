"""dsfilm — DotStudio's toolkit for photoreal, seamlessly looping film scenes in Blender.

Modules (import the ones you need; only `encode` and `assets` work outside Blender):
    assets     CC0 fetching (Poly Haven, ambientCG) into a cache, with a licence log
    materials  PBR materials at real-world scale (no UVs needed), glass, emission, posters
    geometry   procedural meshes: boxes, tubes, panels with holes, spheres, instances
    lighting   sky + sun rigs with presets day / golden / night / rain
    loop       seamless-loop maths: periodic waves, scenery strips, per-frame baking
    render     Cycles / EEVEE setup, stills, frame sequences
    encode     ffmpeg: HEVC 10-bit loop + H.264 preview, seam check
    spec       scene spec (JSON) -> build -> stills / frames (used by tools/film/run.py)

See tools/film/README.md.
"""
