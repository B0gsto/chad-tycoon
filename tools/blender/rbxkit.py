"""rbxkit - tested helpers for Blender 5.2 (headless) -> Roblox asset pipeline.
Run through tools/blender-run.sh (headless, heavy slot); scripts import this with
    sys.path.insert(0, "<repo>/tools/blender"); import rbxkit

The coordinate helpers (rbx_from_blender, rbx_dims, rbx_attach, bake_z_bbox) are pure Python: they import without Blender and
`python3 tools/blender/rbxkit.py` self-tests them. The Blender-facing helpers need bpy.

Export convention: export_fbx writes 1 Blender unit = 1 stud, axis_forward='-Z', axis_up='Y', triangulated, byte-reproducible
(same scene -> identical file, so pipeline/upload.py never re-uploads an unchanged mesh). Vertex colours are exported as sRGB."""
import math, os, sys, time
try:
    import bpy, bmesh
except ImportError:                # the pure helpers stay usable (selftest, Lune-side checks, upload tooling)
    bpy = bmesh = None

ROBLOX_TRI_LIMIT = 20000          # create.roblox.com/docs/art/modeling/specifications

# ---------- Blender <-> Roblox axes (pure) ----------
# Measured with an axis-arrow calibration mesh: the Roblox importer maps an FBX exported with
# axis_forward='-Z', axis_up='Y', FBX_SCALE_UNITS, global_scale 1 as  roblox = (-bx, bz, by),  1 Blender unit = 1 stud.
# So Blender -Y is Roblox forward (-Z), Blender +Z is Roblox up (+Y), Blender -X is Roblox +X (right when facing -Y).
def rbx_from_blender(v):
    """Point or vector in Blender axes -> Roblox axes."""
    return (-v[0], v[2], v[1])

def blender_from_rbx(v):
    """Inverse of rbx_from_blender (the mapping is its own inverse)."""
    return (-v[0], v[2], v[1])

def rbx_dims(dims):
    """Blender bounding-box dimensions (dx, dy, dz) -> Roblox MeshPart.Size (x, y, z): only the axes swap, no signs."""
    return (dims[0], dims[2], dims[1])

def bake_z_bbox(bmin, bmax):
    """Bounding box of a mesh turned 180 degrees about Blender Z around the object origin (the facing +Y export bake)."""
    return (-bmax[0], -bmax[1], bmin[2]), (-bmin[0], -bmin[1], bmax[2])

def rbx_attach(bmin, bmax, origin=(0.0, 0.0, 0.0)):
    """attach = the expected MeshPart.PivotOffset.Position of the imported part: the vector from the bbox centre to the authored
    origin, in Roblox axes. bmin/bmax are the Blender-axis bounds of the EXPORTED vertices relative to the
    object origin (after any export bake); origin is where the authored origin sits in that frame (normally 0,0,0)."""
    centre = tuple((a + b) / 2.0 for a, b in zip(bmin, bmax))
    return rbx_from_blender(tuple(o - c for o, c in zip(origin, centre)))

# ---------- scene / devices ----------
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    return bpy.context.scene

def use_metal_gpu(scene=None):
    scene = scene or bpy.context.scene
    cp = bpy.context.preferences.addons['cycles'].preferences
    cp.compute_device_type = 'METAL'; cp.refresh_devices()
    for d in cp.devices: d.use = (d.type == 'METAL')
    scene.render.engine = 'CYCLES'; scene.cycles.device = 'GPU'

BAKE_DEVICE = os.environ.get("RBXKIT_BAKE_DEVICE", "CPU")   # "CPU" (default, reproducible) or "GPU" (Metal, fast, NOT bit-stable)

def use_bake_device(scene=None):
    """Cycles device for every texture bake. CPU by default: the Metal GPU bakes of the state maps (Color/Metalness/Emissive) came out
    1 LSB different from run to run (reviewed defect: 6 of the 8 probe atlas PNGs), which made upload.py's output-byte recipe change
    on every rebuild. Cycles on the CPU with a fixed seed (shardkit.CYCLES_SEED) is bit-stable. RBXKIT_BAKE_DEVICE=GPU opts out."""
    scene = scene or bpy.context.scene
    if BAKE_DEVICE == "GPU":
        return use_metal_gpu(scene)
    scene.render.engine = 'CYCLES'; scene.cycles.device = 'CPU'
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.seed = 1337; scene.cycles.use_animated_seed = False

# ---------- mesh utils ----------
def tris(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)

def apply_modifiers(ob):
    """Context-free modifier apply (works headless, incl. geometry nodes - realize instances first!)."""
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
    old = ob.data; ob.modifiers.clear(); ob.data = me
    if old.users == 0: bpy.data.meshes.remove(old)
    return ob

def decimate_to(ob, target_tris, iterations=4):
    """Collapse-decimate until under target_tris (Roblox hard cap 20k/mesh)."""
    for _ in range(iterations):
        cur = tris(ob)
        if cur <= target_tris: break
        m = ob.modifiers.new("Dec", 'DECIMATE'); m.decimate_type = 'COLLAPSE'
        m.ratio = max(0.01, target_tris / cur * 0.98); m.use_collapse_triangulate = True
        apply_modifiers(ob)
    return tris(ob)

def select_only(ob):
    for o in bpy.context.scene.objects: o.select_set(False)
    ob.select_set(True); bpy.context.view_layer.objects.active = ob

def smart_uv(ob, angle=66, margin=0.02):
    select_only(ob)
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=margin, correct_aspect=True)
    bpy.ops.uv.pack_islands(margin=0.01, rotate=True, shape_method='CONCAVE')
    bpy.ops.object.mode_set(mode='OBJECT')

# ---------- baking ----------
def new_bake_image(name, res, non_color):
    img = bpy.data.images.new(name, res, res, alpha=False)
    img.colorspace_settings.name = 'Non-Color' if non_color else 'sRGB'
    return img

def bake_pbr(high, low, out_dir, name, res=1024, samples=32, ao_samples=128,
             cage=0.05, max_ray=0.1, maps=("Color", "Normal", "Roughness", "Metalness", "AO")):
    """Selected-to-active bake high->low. Color/Metalness go through an Emission
    re-route (DIFFUSE color pass bakes metal areas BLACK)."""
    sc = bpy.context.scene; use_bake_device(sc)
    bk = sc.render.bake
    bk.use_selected_to_active = True; bk.cage_extrusion = cage; bk.max_ray_distance = max_ray
    bk.margin = 16; bk.margin_type = 'EXTEND'
    if not low.data.materials:
        low.data.materials.append(bpy.data.materials.new(name + "_MAT"))
    lmat = low.data.materials[0]; lnt = lmat.node_tree
    imgs = {}
    for key in maps:
        imgs[key] = new_bake_image(f"{name}_{key}", res, key != "Color")
        n = lnt.nodes.new('ShaderNodeTexImage'); n.image = imgs[key]; n.name = "BAKE_" + key
    # remember hi materials' outputs to temporarily reroute
    hmats = [s.material for s in high.material_slots if s.material]
    def reroute(socket_name):
        saved = []
        for m in hmats:
            nt = m.node_tree; out = next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL' and n.is_active_output)
            bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
            src = bsdf.inputs[socket_name]
            em = nt.nodes.new('ShaderNodeEmission'); em.name = "_BAKE_EM"
            if src.is_linked: nt.links.new(src.links[0].from_socket, em.inputs['Color'])
            else:
                v = src.default_value
                em.inputs['Color'].default_value = (v[0], v[1], v[2], 1) if hasattr(v, '__len__') else (v, v, v, 1)
            prev = out.inputs['Surface'].links[0].from_socket
            nt.links.new(em.outputs['Emission'], out.inputs['Surface']); saved.append((nt, out, prev, em))
        return saved
    def restore(saved):
        for nt, out, prev, em in saved:
            nt.links.new(prev, out.inputs['Surface']); nt.nodes.remove(em)
    for o in sc.objects: o.select_set(o in (high, low))
    bpy.context.view_layer.objects.active = low
    for key in maps:
        lnt.nodes.active = lnt.nodes["BAKE_" + key]; t0 = time.time()
        if key == "Color":
            sc.cycles.samples = samples; s = reroute('Base Color'); bpy.ops.object.bake(type='EMIT'); restore(s)
        elif key == "Metalness":
            sc.cycles.samples = samples; s = reroute('Metallic'); bpy.ops.object.bake(type='EMIT'); restore(s)
        elif key == "Normal":   # Blender default +X +Y +Z tangent = OpenGL = what Roblox wants
            sc.cycles.samples = samples
            bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT', normal_r='POS_X', normal_g='POS_Y', normal_b='POS_Z')
        elif key == "Roughness":
            sc.cycles.samples = samples; bpy.ops.object.bake(type='ROUGHNESS')
        elif key == "AO":
            sc.cycles.samples = ao_samples; bpy.ops.object.bake(type='AO')
        p = os.path.join(out_dir, f"{name}_{key}.png")
        imgs[key].filepath_raw = p; imgs[key].file_format = 'PNG'; imgs[key].save()
        print(f"  baked {key} {time.time()-t0:.2f}s -> {p}")
    # wire the low material for export (glTF packs Metal+Rough into one ORM-style texture automatically)
    b = next(n for n in lnt.nodes if n.type == 'BSDF_PRINCIPLED')
    L = lnt.links
    if "Color" in imgs: L.new(lnt.nodes["BAKE_Color"].outputs['Color'], b.inputs['Base Color'])
    if "Roughness" in imgs: L.new(lnt.nodes["BAKE_Roughness"].outputs['Color'], b.inputs['Roughness'])
    if "Metalness" in imgs: L.new(lnt.nodes["BAKE_Metalness"].outputs['Color'], b.inputs['Metallic'])
    if "Normal" in imgs:
        nm = lnt.nodes.new('ShaderNodeNormalMap'); L.new(lnt.nodes["BAKE_Normal"].outputs['Color'], nm.inputs['Color'])
        L.new(nm.outputs['Normal'], b.inputs['Normal'])
    lmat.use_backface_culling = True   # else glTF marks doubleSided
    return imgs

def multiply_ao_into_color(imgs, strength=0.6):
    """Roblox has no AO slot: bake AO into albedo (numpy-free, uses foreach_get)."""
    import array
    c, a = imgs["Color"], imgs["AO"]; n = len(c.pixels)
    cp = array.array('f', [0.0]) * n; ap = array.array('f', [0.0]) * n
    c.pixels.foreach_get(cp); a.pixels.foreach_get(ap)
    for i in range(0, n, 4):
        f = 1.0 - strength * (1.0 - ap[i])
        cp[i] *= f; cp[i+1] *= f; cp[i+2] *= f
    c.pixels.foreach_set(cp); c.save()

# ---------- export ----------
FBX_FIXED_TIME = (2000, 1, 1, 0, 0, 0)   # the CreationTimeStamp / CreationTime every export is stamped with

def _stable_hash(key):
    """A process-independent stand-in for hash(): sha1 of repr(key) as a positive 63-bit int. io_scene_fbx derives every object UID
    from hash(key), and str hashes are randomized per Blender process, so two identical exports differed in every UID."""
    import hashlib
    return int.from_bytes(hashlib.sha1(repr(key).encode("utf-8")).digest()[:8], "big") >> 1

def _fbx_modules():
    import importlib
    for base in ("io_scene_fbx", "bl_ext.blender_org.io_scene_fbx"):
        try:
            return importlib.import_module(base + ".fbx_utils"), importlib.import_module(base + ".export_fbx_bin")
        except ImportError:
            continue
    raise RuntimeError("io_scene_fbx is not importable: cannot make the FBX export reproducible")

def make_fbx_deterministic():
    """Make bpy.ops.export_scene.fbx reproducible: same scene -> byte-identical file, in any process, at any time (the reviewed
    defect: two builds of the same script differed by the FBX header timestamp and the 4-byte object UIDs, which made every regen
    re-upload every Model). Idempotent. Patches (in this Blender process only):
      fbx_utils.hash            -> sha1-based stable hash (UIDs), and the UID caches are emptied on every call so a file never
                                   depends on what was exported before it in the same process
      export_fbx_bin.fbx_header_elements -> always stamped FBX_FIXED_TIME"""
    import datetime
    fu, eb = _fbx_modules()
    fu.hash = _stable_hash
    fu._keys_to_uuids.clear()
    fu._uuids_to_keys.clear()
    if not getattr(eb.fbx_header_elements, "_rbxkit_fixed", False):
        orig = eb.fbx_header_elements
        def fixed(root, scene_data, time=None):
            return orig(root, scene_data, time=datetime.datetime(*FBX_FIXED_TIME))
        fixed._rbxkit_fixed = True
        eb.fbx_header_elements = fixed

def export_fbx(objs, path, bake_z=False, embed_textures=True):
    """FBX for the Roblox importer. bake_z=True bakes a 180-degree turn about Z around each object's origin into the exported
    vertices (kits authored facing Blender +Y: the importer then lands the front on Roblox -Z); the scene objects
    are left untouched (the bake happens on temporary copies). embed_textures=False writes no textures at all (the kit's textures
    are uploaded as Images and applied as SurfaceAppearance later)."""
    make_fbx_deterministic()
    for o in bpy.context.scene.objects: o.select_set(False)
    for o in objs: assert tris(o) <= ROBLOX_TRI_LIMIT, f"{o.name} has {tris(o)} tris > {ROBLOX_TRI_LIMIT}"
    temps = []
    export_objs = list(objs)
    if bake_z:
        export_objs = []
        for o in objs:
            c = o.copy(); c.data = o.data.copy(); c.name = o.name          # the copy keeps the name (the original is renamed first)
            temps.append((o, o.name, c))
        for o, name, c in temps:
            o.name = name + "__orig"
            c.name = name
            bpy.context.scene.collection.objects.link(c)
            c.rotation_mode = 'XYZ'; c.rotation_euler[2] += math.pi
            select_only(c); bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
            export_objs.append(c)
    for o in bpy.context.scene.objects: o.select_set(o in export_objs)
    bpy.context.view_layer.objects.active = export_objs[0]
    try:
        bpy.ops.export_scene.fbx(filepath=path, use_selection=True, object_types={'MESH', 'ARMATURE'},
            apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS', global_scale=1.0,  # 1 BU = 1 stud with importer "Stud"
            axis_forward='-Z', axis_up='Y', use_mesh_modifiers=True, mesh_smooth_type='FACE',
            use_triangles=True, use_tspace=True, add_leaf_bones=False, bake_anim=False, colors_type='SRGB',
            path_mode='COPY' if embed_textures else 'STRIP', embed_textures=bool(embed_textures))
    finally:
        for o, name, c in temps:
            bpy.data.objects.remove(c, do_unlink=True)
            o.name = name

def export_glb(objs, path):
    for o in bpy.context.scene.objects: o.select_set(o in objs)
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', use_selection=True, export_yup=True,
        export_apply=True, export_materials='EXPORT', export_image_format='AUTO', export_animations=False,
        export_texcoords=True, export_normals=True)

# ---------- marketing renders ----------
def setup_render(engine='BLENDER_EEVEE', w=1920, h=1080, samples=64, transparent=False, bloom=0.0):
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage = w, h, 100
    sc.render.film_transparent = transparent
    sc.view_settings.view_transform = 'AgX'; sc.view_settings.look = 'AgX - Punchy'
    if engine == 'BLENDER_EEVEE':
        sc.render.engine = 'BLENDER_EEVEE'; e = sc.eevee
        e.taa_render_samples = samples; e.use_raytracing = True; e.use_shadows = True; e.use_fast_gi = True
    else:
        use_metal_gpu(sc); sc.cycles.samples = samples; sc.cycles.use_denoising = True; sc.cycles.denoising_use_gpu = True
    if bloom > 0:   # EEVEE bloom was removed in 4.2; 5.x compositor = node group + Group Output
        ng = bpy.data.node_groups.new("Post", 'CompositorNodeTree'); sc.compositing_node_group = ng
        ng.interface.new_socket("Image", in_out='OUTPUT', socket_type='NodeSocketColor')
        rl = ng.nodes.new('CompositorNodeRLayers'); gl = ng.nodes.new('CompositorNodeGlare'); out = ng.nodes.new('NodeGroupOutput')
        gl.inputs['Type'].default_value = 'Bloom'; gl.inputs['Strength'].default_value = bloom
        gl.inputs['Threshold'].default_value = 1.0
        ng.links.new(rl.outputs['Image'], gl.inputs['Image']); ng.links.new(gl.outputs['Image'], out.inputs[0])
    return sc

def render_to(path):
    sc = bpy.context.scene; sc.render.image_settings.file_format = 'PNG'
    sc.render.filepath = path; bpy.ops.render.render(write_still=True)

def split_by_grid(ob, cell=64.0, limit=ROBLOX_TRI_LIMIT):
    """Split a big mesh (e.g. terrain/cliff set) into XY grid chunks, each <= limit tris.
    Recurse with half cell size if a chunk is still too big. Returns list of objects."""
    import bmesh, math
    from collections import defaultdict
    me = ob.data; buckets = defaultdict(list)
    for p in me.polygons:
        c = p.center; buckets[(math.floor(c.x / cell), math.floor(c.y / cell))].append(p.index)
    out = []
    for key, idxs in buckets.items():
        bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
        keep = set(idxs)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.index not in keep], context='FACES')
        nm = bpy.data.meshes.new(f"{ob.name}_{key[0]}_{key[1]}"); bm.to_mesh(nm); bm.free()
        for m in me.materials: nm.materials.append(m)
        no = bpy.data.objects.new(nm.name, nm); no.matrix_world = ob.matrix_world.copy()
        bpy.context.scene.collection.objects.link(no)
        out += split_by_grid(no, cell / 2, limit) if tris(no) > limit and cell > 1 else [no]
        if tris(no) > limit and cell > 1: bpy.data.objects.remove(no)
    return out


# ---------- emissive / single-channel EMIT bakes ----------
def _material_output(nt):
    return next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL' and n.is_active_output)

def _emit_material(name, build):
    """A throw-away emission-only material. build(nt) -> an output socket that feeds Emission Color."""
    mat = bpy.data.materials.new(name); mat.use_nodes = True; nt = mat.node_tree
    for n in list(nt.nodes):
        if n.type != 'OUTPUT_MATERIAL': nt.nodes.remove(n)
    out = next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL')
    em = nt.nodes.new('ShaderNodeEmission'); em.inputs['Strength'].default_value = 1.0
    nt.links.new(build(nt), em.inputs['Color']); nt.links.new(em.outputs['Emission'], out.inputs['Surface'])
    return mat

def bake_emit_map(high, low, image, build, samples=16, cage=0.05, max_ray=0.1, margin=16, clear=True, name="EMITMAP"):
    """Selected-to-active EMIT bake of whatever build(nt) returns (an output socket in an emission-only material that replaces
    high's materials for the duration) into `image` on low's UVs. Cycles has no roughness/metalness/colour bake types without a
    Principled BSDF, so every single-channel map is baked this way. clear=False accumulates several parts into one atlas image.
    The image must be an image of the right colour space (new_bake_image(name, res, non_color)). Returns image."""
    sc = bpy.context.scene; use_bake_device(sc)
    bk = sc.render.bake; bk.use_selected_to_active = True; bk.cage_extrusion = cage; bk.max_ray_distance = max_ray
    bk.margin = margin; bk.margin_type = 'EXTEND'; bk.use_clear = bool(clear)
    if not low.data.materials: low.data.materials.append(bpy.data.materials.new(low.name + "_MAT"))
    lmat = low.data.materials[0]; lmat.use_nodes = True; lnt = lmat.node_tree
    node = lnt.nodes.new('ShaderNodeTexImage'); node.image = image; lnt.nodes.active = node
    hmat_saved = [s.material for s in high.material_slots]
    emat = _emit_material(name, build)
    high.data.materials.clear(); high.data.materials.append(emat)
    for o in sc.objects: o.select_set(o in (high, low))
    bpy.context.view_layer.objects.active = low
    sc.cycles.samples = samples
    try:
        bpy.ops.object.bake(type='EMIT')
    finally:
        high.data.materials.clear()
        for m in hmat_saved: high.data.materials.append(m)
        lnt.nodes.remove(node); bpy.data.materials.remove(emat)
    return image

def bake_emissive(high, low, image, attribute="seam", lo=0.0, hi=1.0, **kw):
    """Emissive mask bake (e.g. a seam or crack mask): the float attribute
    `attribute` of the high mesh, remapped [lo, hi] -> [0, 1], baked to a grayscale 8-bit-style map on low's UVs. Roblox's emissive
    slot is single channel (the red channel is used). image: new_bake_image(name, res, non_color=True)."""
    def build(nt):
        at = nt.nodes.new('ShaderNodeAttribute'); at.attribute_type = 'GEOMETRY'; at.attribute_name = attribute
        mr = nt.nodes.new('ShaderNodeMapRange'); mr.clamp = True
        mr.inputs['From Min'].default_value = lo; mr.inputs['From Max'].default_value = hi
        nt.links.new(at.outputs['Fac'], mr.inputs['Value'])
        rgb = nt.nodes.new('ShaderNodeCombineColor')
        for i in range(3): nt.links.new(mr.outputs['Result'], rgb.inputs[i])
        return rgb.outputs['Color']
    return bake_emit_map(high, low, image, build, name="EMITMASK_" + attribute, **kw)

def image_to_numpy(img):
    import numpy as np
    a = np.empty(len(img.pixels), dtype=np.float32); img.pixels.foreach_get(a); return a.reshape(img.size[1], img.size[0], 4)

def numpy_to_image(img, arr):
    img.pixels.foreach_set(arr.reshape(-1)); img.update()

def save_png(img, path):
    img.filepath_raw = path; img.file_format = 'PNG'; img.save()


if __name__ == "__main__" and bpy is None:
    # pure-Python self-test of the coordinate helpers: python3 tools/blender/rbxkit.py
    import unittest
    class T(unittest.TestCase):
        def test_mapping(self):
            self.assertEqual(rbx_from_blender((1, 2, 3)), (-1, 3, 2))
            self.assertEqual(blender_from_rbx(rbx_from_blender((1, 2, 3))), (1, 2, 3))
            self.assertEqual(rbx_from_blender((0, -1, 0)), (0, 0, -1))       # Blender -Y is Roblox forward (-Z)
            self.assertEqual(rbx_from_blender((0, 0, 1)), (0, 1, 0))         # up stays up
        def test_dims(self):
            self.assertEqual(rbx_dims((2, 6, 4)), (2, 4, 6))
        def test_axis_arrow(self):
            # the AxisArrow calibration: Blender bounds x -0.8..1.15, y -2..3.5, z -0.8..1.45 -> PivotOffset (0.175, -0.325, -0.75)
            a = rbx_attach((-0.8, -2.0, -0.8), (1.15, 3.5, 1.45))
            for got, want in zip(a, (0.175, -0.325, -0.75)): self.assertAlmostEqual(got, want, places=6)
        def test_stable_hash_is_process_independent(self):
            # the FBX UIDs come from hash(): str hashes are randomized per process, so the exporter is patched to _stable_hash
            import subprocess
            code = "import sys; sys.path.insert(0, %r); import rbxkit; print(rbxkit._stable_hash(('B', 'Mesh#Calib', 7)), rbxkit._stable_hash('BObject#CalibBody'))" % os.path.dirname(os.path.abspath(__file__))
            outs = {subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=dict(os.environ, PYTHONHASHSEED=str(seed))).stdout for seed in (1, 2, 3)}
            self.assertEqual(len(outs), 1, outs)
            h = _stable_hash("x")
            self.assertTrue(0 < h < 2 ** 63)
        def test_bake_device_default_is_cpu(self):
            self.assertIn(BAKE_DEVICE, ("CPU", "GPU"))
            if "RBXKIT_BAKE_DEVICE" not in os.environ: self.assertEqual(BAKE_DEVICE, "CPU")
        def test_bake_z(self):
            lo, hi = bake_z_bbox((-0.8, -2.0, -0.8), (1.15, 3.5, 1.45))
            self.assertEqual((lo, hi), ((-1.15, -3.5, -0.8), (0.8, 2.0, 1.45)))
            # baked forward arrow: a +Y front becomes -Y, i.e. Roblox -Z
            self.assertEqual(rbx_from_blender((0, -3.5, 0))[2], -3.5)
    r = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(T))
    sys.exit(0 if r.wasSuccessful() else 1)
