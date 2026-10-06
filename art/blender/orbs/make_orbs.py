"""Aura orbs: one tintable two-piece ball, 1.6 studs across.

    OrbBall   near-white smooth UV sphere (32 x 20, 1216 tris), centred at the origin, with a soft
              baked grey gradient (sRGB ~246 at the top down to ~202 at the bottom). The game tints it
              per orb through MeshPart.Color, which multiplies the baked vertex colours.
    OrbShine  the pure white glossy highlight oval (upper-left-front) plus one small 4-point sparkle
              (upper-right-front), thin patches hugging just outside the sphere. Left untinted, so the
              highlight stays white on every colour.

Roblox scales a mesh to fit its MeshPart.Size and centres it on the part, so the shine part needs its
own size and an offset from the ball centre. The script prints both in Roblox axes (ORBS_SHINE ...)
and writes them to art/out/props/OrbShine.json. Both scale with the ball: at ball size d, multiply
by d / 1.6.

Outputs: art/out/props/OrbBall.fbx / OrbShine.fbx (+ .json), preview/web/models/props__OrbBall.glb /
props__OrbShine.glb. With `-- sheet` it also renders a ~60 ball pile in 8 tints on the pen's aqua
floor into art/out/props/sheet_orbs.png (`-- sheet-only` skips the export). Tags are drawn with
art/blender/orbs/tag_sheet.py (system python + Pillow).
"""

import json
import math
import os
import random
import sys

import bmesh

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "props"))
from _props import GLB_DIR, OUT, ck, export_glb  # noqa: E402

sys.path.insert(0, os.path.join(ck.ROOT, "tools", "blender"))
import rbxkit  # noqa: E402

import bpy  # noqa: E402
from bpy_extras.object_utils import world_to_camera_view  # noqa: E402
from mathutils import Vector  # noqa: E402

R = 0.8  # radius in studs (diameter 1.6)
TOP, BOTTOM = 246, 202  # sRGB grey of the ball's vertex colours at the top / bottom pole
HIGHLIGHT = Vector((-0.34, -0.62, 0.7)).normalized()
SPARKLE = Vector((0.45, -0.62, 0.64)).normalized()

TINTS = {
	"violet": (150, 76, 242), "pink": (255, 92, 170), "yellow": (255, 208, 64), "mint": (72, 214, 150),
	"blue": (80, 170, 255), "orange": (255, 150, 50), "coral": (255, 96, 88), "cream": (255, 236, 200),
}


def _lin(v):
	v = v / 255.0
	return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def _set_colors(obj, fn):
	me = obj.data
	for a in list(me.color_attributes):
		me.color_attributes.remove(a)
	col = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
	me.color_attributes.active_color = col
	me.color_attributes.render_color_index = 0
	for loop in me.loops:
		c = fn(me.vertices[loop.vertex_index].co)
		col.data[loop.index].color = (c, c, c, 1.0)


def make_ball():
	bm = bmesh.new()
	bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=20, radius=R)
	ob = ck.mesh_object("OrbBall", bm, ck.vcol_material("OrbGame", game=True))
	for p in ob.data.polygons:
		p.use_smooth = True

	def grey(co):
		h = (co.z / R + 1) * 0.5  # 0 bottom .. 1 top
		h = h * h * (3 - 2 * h)
		return _lin(BOTTOM + (TOP - BOTTOM) * h)

	_set_colors(ob, grey)
	return ob


def _tangent(n):
	up = Vector((0, 0, 1)) if abs(n.z) < 0.95 else Vector((1, 0, 0))
	u = up.cross(n).normalized()
	return u, n.cross(u).normalized()


def _patch(bm, normal, outline, lift, inner=None):
	"""Fan of `outline` (2D points in the tangent plane at `normal`) wrapped onto the sphere at radius
	R + lift. `inner` (0-1) adds a ring at that fraction so a wide patch bends with the ball."""
	n = Vector(normal).normalized()
	u, v = _tangent(n)
	rr = R + lift
	centre = bm.verts.new(n * rr)

	def ring_at(k):
		return [bm.verts.new((n + u * (x * k / R) + v * (y * k / R)).normalized() * rr) for x, y in outline]

	ring = ring_at(inner if inner else 1.0)
	faces = [(centre, ring[i], ring[(i + 1) % len(ring)]) for i in range(len(ring))]
	if inner:
		outer = ring_at(1.0)
		for i in range(len(ring)):
			j = (i + 1) % len(ring)
			faces.append((ring[i], outer[i], outer[j]))
			faces.append((ring[i], outer[j], ring[j]))
	for f in faces:
		# wind every face so its normal points away from the ball centre
		a, b, c = (x.co for x in f)
		if (b - a).cross(c - a).dot(a + b + c) < 0:
			f = (f[0], f[2], f[1])
		bm.faces.new(f)


def _star(points, r_out, r_in, rot=0.0):
	out = []
	for i in range(points * 2):
		a = math.radians(rot) + math.pi * i / points
		r = r_out if i % 2 == 0 else r_in
		out.append((math.cos(a) * r, math.sin(a) * r))
	return out


def make_shine():
	bm = bmesh.new()
	oval = [(math.cos(a) * 0.3, math.sin(a) * 0.17) for a in (math.tau * i / 24 for i in range(24))]
	tilted = [(x * 0.8 - y * 0.6, x * 0.6 + y * 0.8) for x, y in oval]  # long axis follows the ball's curve
	_patch(bm, HIGHLIGHT, tilted, 0.03, inner=0.55)
	_patch(bm, SPARKLE, _star(4, 0.17, 0.045, 90), 0.032)
	me = bpy.data.meshes.new("OrbShine")
	bm.to_mesh(me)
	bm.free()
	ob = bpy.data.objects.new("OrbShine", me)
	bpy.context.scene.collection.objects.link(ob)
	me.materials.append(ck.vcol_material("OrbGame", game=True))
	for p in me.polygons:
		p.use_smooth = False
	_set_colors(ob, lambda co: 1.0)
	return ob


def bbox(ob):
	pts = [v.co for v in ob.data.vertices]
	lo = tuple(min(p[i] for p in pts) for i in range(3))
	hi = tuple(max(p[i] for p in pts) for i in range(3))
	return lo, hi


def ship(ball, shine):
	out = {}
	for ob in (ball, shine):
		rbxkit.export_fbx([ob], os.path.join(OUT, ob.name + ".fbx"))
		export_glb(ob, os.path.join(GLB_DIR, "props__%s.glb" % ob.name))
		lo, hi = bbox(ob)
		dims = tuple(h - l for l, h in zip(lo, hi))
		centre = tuple((l + h) / 2 for l, h in zip(lo, hi))
		size = [round(v, 4) for v in rbxkit.rbx_dims(dims)]
		offset = [round(v + 0.0, 4) for v in rbxkit.rbx_from_blender(centre)]
		stats = {"kind": ob.name, "tris": rbxkit.tris(ob), "size": size, "offsetFromBallCentre": offset,
			"axes": "Roblox studs [X, Y up, Z]; front faces -Z; at ball diameter 1.6 (scale both by d / 1.6)"}
		with open(os.path.join(OUT, ob.name + ".json"), "w") as f:
			json.dump(stats, f, indent=1)
		print("ORBS_STATS", json.dumps(stats))
		out[ob.name] = stats
	return out


def tint_material(name, rgb):
	"""In-game look: SmoothPlastic-like finish, baked vertex grey multiplied by MeshPart.Color."""
	mat = bpy.data.materials.new(name)
	mat.use_nodes = True
	nt = mat.node_tree
	p = next(nd for nd in nt.nodes if nd.type == "BSDF_PRINCIPLED")
	attr = nt.nodes.new("ShaderNodeVertexColor")
	attr.layer_name = "Col"
	mul = nt.nodes.new("ShaderNodeMix")
	mul.data_type = "RGBA"
	mul.blend_type = "MULTIPLY"
	mul.inputs["Factor"].default_value = 1.0
	nt.links.new(attr.outputs["Color"], mul.inputs[6])
	mul.inputs[7].default_value = tuple(_lin(c) for c in rgb) + (1.0,)
	nt.links.new(mul.outputs[2], p.inputs["Base Color"])
	p.inputs["Roughness"].default_value = 0.42
	p.inputs["Specular IOR Level"].default_value = 0.35
	return mat


def pile_scene(ball, shine, path):
	scene = bpy.context.scene
	ck._setup_render(scene, 1600, 1000, False, samples=48)
	ball.hide_render = shine.hide_render = True
	white = ck.matte_material("ShineWhite", (1.0, 1.0, 1.0), 0.35)
	mats = {k: tint_material("Tint_" + k, rgb) for k, rgb in TINTS.items()}
	rnd = random.Random(11)
	kinds = [k for k in TINTS for _ in range(8)][:62]
	rnd.shuffle(kinds)
	d = 2 * R
	placed = []
	for kind in kinds:
		best = None
		for _ in range(300):
			x, y = rnd.uniform(-4.6, 4.6), rnd.uniform(-2.6, 2.4)
			rests = [pz + math.sqrt(d * d - dd * dd) for px, py, pz, _k in placed
				for dd in (math.hypot(x - px, y - py),) if dd < d]
			z = max([R] + rests)
			if z > R and sum(1 for h in rests if h > z - 0.4) < 2:
				continue  # perched on a single ball: would roll off
			score = z + 0.07 * (x * x + 1.8 * y * y)  # lowest spot wins, nearer the middle: a soft heap
			if best is None or score < best[3]:
				best = (x, y, z, score)
		x, y, z, _s = best
		placed.append((x, y, z, kind))
		rz = rnd.uniform(-0.25, 0.25)
		for src, mat in ((ball, mats[kind]), (shine, white)):
			ob = src.copy()
			ob.data = src.data.copy()
			ob.data.materials.clear()
			ob.data.materials.append(mat)
			ob.hide_render = False
			ob.location = (x, y, z)
			ob.rotation_euler = (0, 0, rz)
			scene.collection.objects.link(ob)
	bpy.ops.mesh.primitive_plane_add(size=80, location=(0, 0, 0))
	floor = bpy.context.active_object
	floor.data.materials.append(ck.matte_material("Floor", tuple(_lin(v) for v in (150, 228, 226)), 0.85))
	sun = bpy.data.lights.new("Sun", "SUN")
	sun.energy = 2.3
	sun.angle = math.radians(4)
	so = bpy.data.objects.new("Sun", sun)
	so.rotation_euler = (math.radians(38), 0, math.radians(-30))
	scene.collection.objects.link(so)
	world = bpy.data.worlds.new("Sky")
	world.use_nodes = True
	bg = world.node_tree.nodes["Background"]
	bg.inputs[0].default_value = (0.62, 0.8, 1.0, 1)
	bg.inputs[1].default_value = 0.55
	scene.world = world
	cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
	cam.data.lens = 42
	cam.location = Vector((0, -17.5, 12.5))
	cam.rotation_euler = (Vector((0, 0.9, 1.9)) - cam.location).to_track_quat("-Z", "Y").to_euler()
	scene.collection.objects.link(cam)
	scene.camera = cam
	scene.render.filepath = path
	bpy.ops.render.render(write_still=True)
	# tag anchors: the top of a few balls, in image pixels (origin top-left)
	bpy.context.view_layer.update()
	tops = sorted(placed, key=lambda p: -p[2])
	picks = [tops[0], tops[len(tops) // 3], tops[len(tops) // 2 + 3], tops[-4]]
	tags = []
	for (x, y, z, kind), text in zip(picks, ("x30", "x14", "x3", "x3")):
		co = world_to_camera_view(scene, cam, Vector((x, y, z + R * 1.15)))
		tags.append({"x": co.x * scene.render.resolution_x, "y": (1 - co.y) * scene.render.resolution_y,
			"text": text, "rgb": TINTS[kind]})
	with open(path + ".tags.json", "w") as f:
		json.dump(tags, f)
	print("ORBS_PILE", len(placed), "balls, top z", round(max(p[2] for p in placed), 2))


if __name__ == "__main__":
	argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
	ck.reset_scene()
	ball, shine = make_ball(), make_shine()
	print("ORBS_TRIS", "ball", rbxkit.tris(ball), "shine", rbxkit.tris(shine))
	if "sheet-only" not in argv:
		ship(ball, shine)
	if "sheet" in argv or "sheet-only" in argv:
		pile_scene(ball, shine, os.path.join(OUT, "sheet_orbs.png"))
