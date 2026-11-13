"""Procedural geometry helpers (metres, Z up). Every function returns the new object, linked into
the given collection; meshes are smooth-shaded with a 'smooth by angle' modifier so hard edges
stay crisp. Curves are converted to meshes immediately (cheaper to render, easy to edit).

    box(name, size, loc, mat, coll, bevel=0, segs=3, rot=(0,0,0), subsurf=0, parent=None)
    tube(name, points, radius, mat, coll)                 # straight segments (poles, rails, wires)
    smooth_tube(name, points, radius, mat, coll, taper)   # bezier through points (sleeves, ties)
    slab(name, loops, depth, mats, coll, side_mat=None)   # 2D outline(s) with holes -> extruded
                                                          #   panel in the XZ plane (walls, doors)
    rrect(x0, y0, x1, y1, r)                              # rounded-rectangle outline for slab()
    plane_uv(name, w, h, mat, coll, loc, rot)             # UV'd quad for image_mat posters
    sphere(name, r, loc, mat, coll, scale)                # UV sphere
    empty(name, coll, loc, parent)                        # pivot/null
    instance(name, collection, coll, loc, rot, scale)     # collection instance (cheap copies)
    append_collection(blend_path, name)                   # import a collection from a .blend
    no_shadow(obj)                                        # glass, lamps: let light through
"""
import math

import bmesh
import bpy
from mathutils import Vector

_SBA = {}


def link(ob, coll):
    coll.objects.link(ob)
    return ob


def from_bm(name, bm, mats, coll, parent=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in (mats if isinstance(mats, (list, tuple)) else [mats]):
        if m is not None:
            me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    link(ob, coll)
    if parent is not None:
        ob.parent = parent
    return ob


def smooth_by_angle(ob, angle=35):
    """Smooth shading with hard edges above `angle` degrees (Blender 4.1+ has no auto smooth)."""
    me = ob.data
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    if angle not in _SBA:
        ng = bpy.data.node_groups.new(f"SmoothByAngle{angle}", "GeometryNodeTree")
        ng.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
        ng.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
        gi, go = ng.nodes.new("NodeGroupInput"), ng.nodes.new("NodeGroupOutput")
        ss = ng.nodes.new("GeometryNodeSetShadeSmooth")
        ss.domain = "EDGE"
        ea = ng.nodes.new("GeometryNodeInputMeshEdgeAngle")
        cmp = ng.nodes.new("FunctionNodeCompare")
        cmp.data_type = "FLOAT"
        cmp.operation = "LESS_EQUAL"
        cmp.inputs["B"].default_value = math.radians(angle)
        ng.links.new(ea.outputs["Unsigned Angle"], cmp.inputs["A"])
        ng.links.new(gi.outputs[0], ss.inputs["Geometry"])
        ng.links.new(cmp.outputs["Result"], ss.inputs["Shade Smooth"])
        ng.links.new(ss.outputs[0], go.inputs[0])
        _SBA[angle] = ng
    ob.modifiers.new("smooth", "NODES").node_group = _SBA[angle]
    return ob


def box(name, size, loc, mat, coll, bevel=0.0, segs=3, rot=(0, 0, 0), subsurf=0, parent=None, angle=35):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    ob = from_bm(name, bm, mat, coll, parent)
    ob.location = loc
    ob.rotation_euler = rot
    if bevel:
        b = ob.modifiers.new("bevel", "BEVEL")
        b.width = bevel
        b.segments = segs
        b.limit_method = "ANGLE"
    if subsurf:
        s = ob.modifiers.new("sub", "SUBSURF")
        s.levels = s.render_levels = subsurf
    return smooth_by_angle(ob, angle)


def to_mesh(ob):
    """Converts a curve/any object to a plain mesh object in place (same name, transform)."""
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    name, colls, mw, par = ob.name, list(ob.users_collection), ob.matrix_world.copy(), ob.parent
    data = ob.data
    bpy.data.objects.remove(ob)
    if isinstance(data, bpy.types.Curve):
        bpy.data.curves.remove(data)
    nob = bpy.data.objects.new(name, me)
    for c in colls:
        c.objects.link(nob)
    nob.matrix_world = mw
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    return nob


def _curve_obj(name, coll, r, caps=True, res=4):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r
    cu.bevel_resolution = res
    cu.use_fill_caps = caps
    ob = bpy.data.objects.new(name, cu)
    link(ob, coll)
    return cu, ob


def tube(name, pts, r, mat, coll, parent=None, caps=True, res=3):
    cu, ob = _curve_obj(name, coll, r, caps, res)
    sp = cu.splines.new("POLY")
    sp.points.add(len(pts) - 1)
    for p, q in zip(sp.points, pts):
        p.co = (*q, 1)
    ob = to_mesh(ob)
    ob.data.materials.append(mat)
    if parent is not None:
        ob.parent = parent
    return ob


def smooth_tube(name, pts, r, mat, coll, parent=None, taper=None, res_u=10, caps=True):
    cu, ob = _curve_obj(name, coll, r, caps, 4)
    cu.resolution_u = res_u
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    for i, (bp, q) in enumerate(zip(sp.bezier_points, pts)):
        bp.co = q
        bp.handle_left_type = bp.handle_right_type = "AUTO"
        if taper:
            bp.radius = taper[i]
    ob = to_mesh(ob)
    ob.data.materials.append(mat)
    if parent is not None:
        ob.parent = parent
    return ob


def rrect(x0, y0, x1, y1, r, seg=6):
    r = max(min(r, (x1 - x0) / 2, (y1 - y0) / 2), 1e-4)
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def slab(name, loops, depth, mats, coll, side_mat=None, parent=None):
    """Even-odd filled 2D loops (outer + holes, (x, z) points) extruded `depth` along Y, centred
    on y=0, standing in the XZ plane. Faces lining the holes/edges get material index `side_mat`."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "2D"
    cu.fill_mode = "BOTH"
    cu.extrude = depth / 2
    for lp in loops:
        sp = cu.splines.new("POLY")
        sp.points.add(len(lp) - 1)
        for p, q in zip(sp.points, lp):
            p.co = (q[0], q[1], 0, 1)
        sp.use_cyclic_u = True
    ob = bpy.data.objects.new(name, cu)
    link(ob, coll)
    ob.rotation_euler = (math.radians(90), 0, 0)
    ob = to_mesh(ob)
    me = ob.data
    for m in (mats if isinstance(mats, (list, tuple)) else [mats]):
        me.materials.append(m)
    me.polygons.foreach_set("use_smooth", [False] * len(me.polygons))
    if side_mat is not None:
        for p in me.polygons:
            if abs(p.normal.z) < 0.5:
                p.material_index = side_mat
    if parent is not None:
        ob.parent = parent
    return ob


def plane_uv(name, w, h, mat, coll, loc, rot=(0, 0, 0), parent=None):
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new()
    vs = [bm.verts.new((x * w / 2, y * h / 2, 0)) for x, y in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    f = bm.faces.new(vs)
    for l, (u, v) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        l[uv].uv = (u, v)
    ob = from_bm(name, bm, mat, coll, parent)
    ob.location = loc
    ob.rotation_euler = rot
    return ob


def sphere(name, r, loc, mat, coll, scale=(1, 1, 1), segs=48, rings=32, parent=None, rot=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r)
    bmesh.ops.scale(bm, vec=Vector(scale), verts=bm.verts)
    ob = from_bm(name, bm, mat, coll, parent)
    ob.location = loc
    ob.rotation_euler = rot
    ob.data.polygons.foreach_set("use_smooth", [True] * len(ob.data.polygons))
    return ob


def empty(name, coll, loc=(0, 0, 0), parent=None):
    e = bpy.data.objects.new(name, None)
    link(e, coll)
    if parent is not None:
        e.parent = parent
    e.location = loc
    return e


def instance(name, collection, coll, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), parent=None):
    e = bpy.data.objects.new(name, None)
    e.instance_type = "COLLECTION"
    e.instance_collection = collection
    e.location, e.rotation_euler, e.scale = loc, rot, scale
    link(e, coll)
    if parent is not None:
        e.parent = parent
    return e


def append_collection(path, cname):
    """Appends collection `cname` from a .blend (not linked into the scene: instance it)."""
    with bpy.data.libraries.load(path, link=False) as (src, dst):
        dst.collections = [cname]
    return dst.collections[0]


class Batch:
    """Many simple parts merged into one mesh per material — thousands of buildings, windows or
    balconies cost a handful of objects. Coordinates are the batch object's (keep it at the
    origin, scale 1) so box-projected / object-space materials stay at real-world scale.

        b = Batch("Houses", coll)
        b.box((w, d, h), (x, y, z), mat, rot_z=0.0)
        b.poly(verts, faces, mat, loc=(x, y, z))       # any small mesh (e.g. a gable roof)
        b.finish()                                      # -> list of objects
    """

    def __init__(self, name, coll):
        self.name, self.coll = name, coll
        self.parts = {}

    def _bm(self, mat):
        k = mat.name if mat else "_"
        if k not in self.parts:
            self.parts[k] = (bmesh.new(), mat)
        return self.parts[k][0]

    def box(self, size, loc, mat, rot_z=0.0):
        from mathutils import Matrix
        m = Matrix.Translation(loc) @ Matrix.Rotation(rot_z, 4, "Z") @ Matrix.Diagonal((*size, 1.0))
        bmesh.ops.create_cube(self._bm(mat), size=1.0, matrix=m)

    def cylinder(self, r, h, loc, mat, segs=16):
        from mathutils import Matrix
        bmesh.ops.create_cone(self._bm(mat), cap_ends=True, segments=segs, radius1=r, radius2=r, depth=h,
                              matrix=Matrix.Translation(loc))

    def poly(self, verts, faces, mat, loc=(0, 0, 0)):
        bm = self._bm(mat)
        vs = [bm.verts.new(Vector(v) + Vector(loc)) for v in verts]
        for f in faces:
            bm.faces.new([vs[i] for i in f])

    def finish(self, angle=30):
        out = []
        for k, (bm, mat) in self.parts.items():
            ob = from_bm(f"{self.name}_{k}", bm, mat, self.coll)
            ob.data.polygons.foreach_set("use_smooth", [False] * len(ob.data.polygons))
            out.append(ob)
        self.parts = {}
        return out


def no_shadow(ob):
    ob.visible_shadow = False
    return ob


def look_at(ob, frm, target, roll=0.0):
    """Points `ob` (camera or light: looks down its -Z) from world point `frm` toward `target`."""
    d = Vector(target) - Vector(frm)
    q = d.to_track_quat("-Z", "Y")
    e = q.to_euler()
    if roll:
        e.rotate_axis("Z", math.radians(roll))
    ob.rotation_euler = e
    return ob
