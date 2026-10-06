"""Pipeline proof assets: a 256 px coloured sphere PNG (transparent background) and a ~4 stud bevelled cube FBX with
vertex colours. Run: tools/blender-run.sh art/proof/make_proof.py
Writes art/proof/out/proof_sphere.png and art/proof/out/proof_cube.fbx."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools", "blender"))
import bpy  # noqa: E402
import bmesh  # noqa: E402
import rbxkit  # noqa: E402

OUT = os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)


def srgb(hex_):
    """'#RRGGBB' -> linear RGBA (Blender colour values are linear)."""
    def lin(c):
        c /= 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (lin(int(hex_[1:3], 16)), lin(int(hex_[3:5], 16)), lin(int(hex_[5:7], 16)), 1.0)


# Theme.World-like paint colours (sunny, toy-like)
CORAL, MINT, SUNNY, BLUE = "#FF7A6B", "#5FD3A8", "#FFD24A", "#5AA9FF"


def sphere_png(path):
    rbxkit.reset()
    bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=1.0)
    ob = bpy.context.active_object
    bpy.ops.object.shade_smooth()
    mat = bpy.data.materials.new("Ball")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = srgb(SUNNY)
    bsdf.inputs["Roughness"].default_value = 0.35
    ob.data.materials.append(mat)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = 2.3
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = (0, -6, 0)
    cam.rotation_euler = (1.5707963, 0, 0)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    sun_data = bpy.data.lights.new("Sun", 'SUN')
    sun_data.energy = 4.0
    sun = bpy.data.objects.new("Sun", sun_data)
    sun.rotation_euler = (0.9, 0.3, -0.6)
    bpy.context.scene.collection.objects.link(sun)
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.8, 0.9, 1.0, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
    bpy.context.scene.world = world
    rbxkit.setup_render(w=256, h=256, samples=32, transparent=True)
    bpy.context.scene.render.image_settings.color_mode = 'RGBA'
    rbxkit.render_to(path)


def cube_fbx(path):
    rbxkit.reset()
    me = bpy.data.meshes.new("ProofCube")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=4.0)
    bmesh.ops.bevel(bm, geom=list(bm.edges), offset=0.35, segments=3, profile=0.5, affect='EDGES')
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("ProofCube", me)
    bpy.context.scene.collection.objects.link(ob)
    # face-corner byte colours, picked by the face normal: top coral, bottom blue, X sides mint, Y sides sunny
    attr = me.color_attributes.new("Col", 'BYTE_COLOR', 'CORNER')
    me.color_attributes.active_color = attr
    for poly in me.polygons:
        n = poly.normal
        if n.z > 0.5:
            c = CORAL
        elif n.z < -0.5:
            c = BLUE
        elif abs(n.x) >= abs(n.y):
            c = MINT
        else:
            c = SUNNY
        col = srgb(c)
        for li in poly.loop_indices:
            attr.data[li].color = col
    for poly in me.polygons:
        poly.use_smooth = False
    rbxkit.export_fbx([ob], path, embed_textures=False)
    print("cube tris", rbxkit.tris(ob), "dims", tuple(round(d, 3) for d in ob.dimensions))


sphere_png(os.path.join(OUT, "proof_sphere.png"))
cube_fbx(os.path.join(OUT, "proof_cube.fbx"))
print("PROOF OK")
