// Renders an exported scene (see preview/export/export.luau) with three.js.
// Parts become meshes, SurfaceGuis/BillboardGuis become pre-baked textures.

import * as THREE from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";

const srgb = (c) => new THREE.Color().setRGB(c[0] / 255, c[1] / 255, c[2] / 255, THREE.SRGBColorSpace);

export function cframeMatrix(cf) {
	const [x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22] = cf;
	return new THREE.Matrix4().set(r00, r01, r02, x, r10, r11, r12, y, r20, r21, r22, z, 0, 0, 0, 1);
}

// --- Procedural material textures -----------------------------------------------------

function canvasTexture(size, draw) {
	const canvas = document.createElement("canvas");
	canvas.width = canvas.height = size;
	draw(canvas.getContext("2d"), size);
	const tex = new THREE.CanvasTexture(canvas);
	tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
	tex.colorSpace = THREE.SRGBColorSpace;
	tex.anisotropy = 4;
	return tex;
}

function noise(ctx, s, amount, alpha) {
	for (let i = 0; i < amount; i++) {
		const v = Math.random() * 255;
		ctx.fillStyle = `rgba(${v},${v},${v},${alpha})`;
		ctx.fillRect(Math.random() * s, Math.random() * s, 2, 2);
	}
}

const TEXTURES = {
	Brick: [8, () => canvasTexture(256, (ctx, s) => {
		ctx.fillStyle = "#e8e8e8"; ctx.fillRect(0, 0, s, s);
		ctx.fillStyle = "#9a9a9a";
		const rows = 4, h = s / rows;
		for (let r = 0; r < rows; r++) {
			ctx.fillRect(0, r * h, s, 6);
			const off = r % 2 ? s / 4 : 0;
			for (let c = 0; c < 3; c++) ctx.fillRect(off + c * s / 2, r * h, 6, h);
		}
		noise(ctx, s, 3000, 0.08);
	})],
	WoodPlanks: [4, () => canvasTexture(256, (ctx, s) => {
		ctx.fillStyle = "#d9d9d9"; ctx.fillRect(0, 0, s, s);
		for (let i = 0; i < 4; i++) {
			ctx.fillStyle = i % 2 ? "#cfcfcf" : "#e6e6e6";
			ctx.fillRect(0, i * s / 4, s, s / 4 - 4);
			ctx.fillStyle = "#8c8c8c"; ctx.fillRect(0, i * s / 4 + s / 4 - 4, s, 4);
		}
		for (let i = 0; i < 40; i++) {
			ctx.strokeStyle = "rgba(120,120,120,0.25)";
			ctx.beginPath(); const y = Math.random() * s; ctx.moveTo(0, y); ctx.bezierCurveTo(s / 3, y + 6, s / 2, y - 6, s, y); ctx.stroke();
		}
	})],
	DiamondPlate: [6, () => canvasTexture(256, (ctx, s) => {
		ctx.fillStyle = "#d0d0d0"; ctx.fillRect(0, 0, s, s);
		ctx.fillStyle = "#f4f4f4";
		for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
			ctx.save(); ctx.translate(x * 32 + (y % 2) * 16 + 8, y * 32 + 8); ctx.rotate((y % 2 ? 1 : -1) * 0.7);
			ctx.fillRect(-9, -3, 18, 6); ctx.restore();
		}
	})],
	Slate: [12, () => canvasTexture(256, (ctx, s) => {
		ctx.fillStyle = "#dcdcdc"; ctx.fillRect(0, 0, s, s);
		ctx.strokeStyle = "rgba(90,90,90,0.5)"; ctx.lineWidth = 3;
		for (let i = 0; i < 14; i++) {
			ctx.beginPath();
			let x = Math.random() * s, y = Math.random() * s; ctx.moveTo(x, y);
			for (let k = 0; k < 4; k++) { x += (Math.random() - 0.5) * 90; y += (Math.random() - 0.5) * 90; ctx.lineTo(x, y); }
			ctx.stroke();
		}
		noise(ctx, s, 5000, 0.08);
	})],
	Concrete: [20, () => canvasTexture(256, (ctx, s) => { ctx.fillStyle = "#dedede"; ctx.fillRect(0, 0, s, s); noise(ctx, s, 9000, 0.1); })],
	Fabric: [3, () => canvasTexture(128, (ctx, s) => {
		ctx.fillStyle = "#e0e0e0"; ctx.fillRect(0, 0, s, s);
		for (let i = 0; i < s; i += 4) { ctx.fillStyle = "rgba(0,0,0,0.06)"; ctx.fillRect(i, 0, 2, s); ctx.fillRect(0, i, s, 2); }
	})],
	CorrodedMetal: [4, () => canvasTexture(256, (ctx, s) => {
		ctx.fillStyle = "#d8d8d8"; ctx.fillRect(0, 0, s, s);
		for (let i = 0; i < 60; i++) {
			ctx.fillStyle = `rgba(${120 + Math.random() * 60},${80 + Math.random() * 30},40,0.25)`;
			ctx.beginPath(); ctx.arc(Math.random() * s, Math.random() * s, 4 + Math.random() * 18, 0, 7); ctx.fill();
		}
	})],
	Marble: [6, () => canvasTexture(256, (ctx, s) => {
		ctx.fillStyle = "#f2f2f2"; ctx.fillRect(0, 0, s, s);
		ctx.strokeStyle = "rgba(140,140,150,0.35)"; ctx.lineWidth = 2;
		for (let i = 0; i < 10; i++) { ctx.beginPath(); ctx.moveTo(0, Math.random() * s); ctx.bezierCurveTo(s / 3, Math.random() * s, s / 2, Math.random() * s, s, Math.random() * s); ctx.stroke(); }
	})],
};
const textureCache = {};
function materialTexture(name) {
	const def = TEXTURES[name];
	if (!def) return null;
	if (!textureCache[name]) textureCache[name] = def[1]();
	return { tex: textureCache[name], studs: def[0] };
}

const materialCache = new Map();
function materialFor(part) {
	const key = `${part.material}|${part.color.join(",")}|${part.transparency}|${part.size.map((v) => Math.round(v)).join(",")}`;
	if (materialCache.has(key)) return materialCache.get(key);
	const color = srgb(part.color);
	const opacity = 1 - (part.transparency || 0);
	let mat;
	switch (part.material) {
		case "Neon":
			mat = new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.85, roughness: 1 });
			break;
		case "Glass":
			// Slightly rough so large glass floors don't turn into one sun-glare mirror.
			mat = new THREE.MeshPhysicalMaterial({ color, roughness: 0.22, metalness: 0.1, transparent: true, opacity: Math.min(opacity, 0.45), envMapIntensity: 1.2 });
			break;
		case "ForceField":
			mat = new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.8, transparent: true, opacity: 0.55, blending: THREE.AdditiveBlending, depthWrite: false });
			break;
		case "Metal":
		case "DiamondPlate":
		case "Foil":
		case "CorrodedMetal":
			mat = new THREE.MeshStandardMaterial({ color, metalness: part.material === "Foil" ? 0.9 : 0.55, roughness: part.material === "Foil" ? 0.2 : 0.42, envMapIntensity: 0.9 });
			break;
		case "SmoothPlastic":
		case "Plastic":
			mat = new THREE.MeshStandardMaterial({ color, roughness: 0.55, metalness: 0, envMapIntensity: 0.4 });
			break;
		default:
			mat = new THREE.MeshStandardMaterial({ color, roughness: 0.85, metalness: 0, envMapIntensity: 0.3 });
	}
	const t = materialTexture(part.material);
	if (t) {
		const tex = t.tex.clone();
		tex.needsUpdate = true;
		const [sx, sy, sz] = part.size;
		tex.repeat.set(Math.max(sx, sz) / t.studs, Math.max(sy, Math.min(sx, sz)) / t.studs);
		mat.map = tex;
	}
	if (opacity < 1 && !mat.transparent) {
		mat.transparent = true;
		mat.opacity = opacity;
	}
	materialCache.set(key, mat);
	return mat;
}

const boxGeo = new THREE.BoxGeometry(1, 1, 1);
const sphereGeo = new THREE.SphereGeometry(0.5, 24, 16);
const cylGeo = new THREE.CylinderGeometry(0.5, 0.5, 1, 32).rotateZ(Math.PI / 2);
// Roblox wedge: full bottom and back faces, the slope replaces the front/top.
const wedgeGeo = (() => {
	const A = [-0.5, -0.5, -0.5], B = [0.5, -0.5, -0.5], C = [-0.5, -0.5, 0.5], D = [0.5, -0.5, 0.5], E = [-0.5, 0.5, 0.5], F = [0.5, 0.5, 0.5];
	const tris = [A, B, D, A, D, C, C, D, F, C, F, E, A, E, F, A, F, B, A, C, E, B, F, D];
	const geo = new THREE.BufferGeometry();
	geo.setAttribute("position", new THREE.Float32BufferAttribute(tris.flat(), 3));
	geo.computeVertexNormals();
	return geo;
})();

// Roblox WedgePart: full bottom and back (+Z) faces, slope rising from the
// front-bottom edge (-Z) to the back-top edge (+Z).
const wedgeGeo = (() => {
	const A = [-0.5, -0.5, -0.5], B = [0.5, -0.5, -0.5], C = [-0.5, -0.5, 0.5], D = [0.5, -0.5, 0.5], E = [-0.5, 0.5, 0.5], F = [0.5, 0.5, 0.5];
	const tris = [[A, B, D], [A, D, C], [C, D, F], [C, F, E], [A, E, F], [A, F, B], [A, C, E], [B, F, D]];
	const pos = [], uv = [];
	for (const tri of tris) {
		// Side faces (all x equal) map (z, y); the others map (x, z or y).
		const side = tri.every((v) => v[0] === tri[0][0]);
		const back = tri.every((v) => v[2] === 0.5);
		for (const [x, y, z] of tri) {
			pos.push(x, y, z);
			if (side) uv.push(z + 0.5, y + 0.5);
			else if (back) uv.push(x + 0.5, y + 0.5);
			else uv.push(x + 0.5, z + 0.5);
		}
	}
	const geo = new THREE.BufferGeometry();
	geo.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
	geo.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2));
	geo.computeVertexNormals();
	return geo;
})();

function buildPart(part) {
	const [sx, sy, sz] = part.size;
	let mesh;
	if (part.shape === "Ball") {
		const d = Math.min(sx, sy, sz);
		mesh = new THREE.Mesh(sphereGeo, materialFor(part));
		mesh.scale.set(d, d, d);
	} else if (part.shape === "Cylinder") {
		const d = Math.min(sy, sz);
		mesh = new THREE.Mesh(cylGeo, materialFor(part));
		mesh.scale.set(sx, d, d);
	} else if (part.shape === "Wedge") {
		mesh = new THREE.Mesh(wedgeGeo, materialFor(part));
		mesh.scale.set(sx, sy, sz);
	} else {
		mesh = new THREE.Mesh(boxGeo, materialFor(part));
		mesh.scale.set(sx, sy, sz);
	}
	const m = cframeMatrix(part.cf);
	const holder = new THREE.Group();
	holder.matrixAutoUpdate = false;
	holder.matrix.copy(m);
	holder.add(mesh);
	if (part.highlight) {
		// Roblox Highlight: tinted overlay slightly larger than the part.
		const glow = new THREE.Mesh(mesh.geometry, new THREE.MeshBasicMaterial({ color: srgb(part.highlight), transparent: true, opacity: 0.5, depthWrite: false, toneMapped: false }));
		glow.scale.copy(mesh.scale).multiplyScalar(1.04);
		holder.add(glow);
	}
	const glassy = part.material === "Glass" || part.material === "ForceField" || part.transparency > 0;
	mesh.castShadow = !glassy && part.material !== "Neon";
	mesh.receiveShadow = true;
	holder.userData.part = part;
	return holder;
}

// Plane placed just outside the given face of a part.
const FACES = {
	Front: { normal: [0, 0, -1], dims: (s) => [s[0], s[1]], rot: [0, Math.PI, 0] },
	Back: { normal: [0, 0, 1], dims: (s) => [s[0], s[1]], rot: [0, 0, 0] },
	Right: { normal: [1, 0, 0], dims: (s) => [s[2], s[1]], rot: [0, Math.PI / 2, 0] },
	Left: { normal: [-1, 0, 0], dims: (s) => [s[2], s[1]], rot: [0, -Math.PI / 2, 0] },
	Top: { normal: [0, 1, 0], dims: (s) => [s[0], s[2]], rot: [-Math.PI / 2, 0, 0] },
	Bottom: { normal: [0, -1, 0], dims: (s) => [s[0], s[2]], rot: [Math.PI / 2, 0, 0] },
};

export function surfaceDims(surface, part) {
	const face = FACES[surface.face] || FACES.Front;
	const [w, h] = face.dims(part.size);
	if (surface.sizing === "PixelsPerStud") {
		return { studs: [w, h], px: [Math.round(w * surface.pixelsPerStud), Math.round(h * surface.pixelsPerStud)] };
	}
	return { studs: [w, h], px: [surface.canvas[0], surface.canvas[1]] };
}

function buildSurface(surface, part, texture) {
	const face = FACES[surface.face] || FACES.Front;
	const { studs } = surfaceDims(surface, part);
	const mat = new THREE.MeshBasicMaterial({ map: texture, transparent: true, toneMapped: false, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -2 });
	const plane = new THREE.Mesh(new THREE.PlaneGeometry(studs[0], studs[1]), mat);
	plane.rotation.set(...face.rot);
	// Cylinders/balls: draw on the flat face at the part's half-size along the normal.
	const half = face.normal.map((n, i) => n * (part.size[i] / 2 + 0.03));
	plane.position.set(...half);
	plane.renderOrder = 2;
	const holder = new THREE.Group();
	holder.matrixAutoUpdate = false;
	holder.matrix.copy(cframeMatrix(part.cf));
	holder.add(plane);
	return holder;
}

function buildBillboard(bb, texture) {
	const mat = new THREE.SpriteMaterial({ map: texture, transparent: true, toneMapped: false, depthWrite: false });
	const sprite = new THREE.Sprite(mat);
	sprite.scale.set(bb.size[0], bb.size[1], 1);
	sprite.position.set(...bb.pos);
	sprite.renderOrder = bb.alwaysOnTop ? 10 : 3;
	if (bb.alwaysOnTop) mat.depthTest = false;
	sprite.userData.maxDistance = bb.maxDistance || 1e9;
	return sprite;
}

function sparkTexture() {
	return canvasTexture(64, (ctx, s) => {
		const g = ctx.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
		g.addColorStop(0, "rgba(255,255,255,1)");
		g.addColorStop(0.35, "rgba(255,255,255,0.6)");
		g.addColorStop(1, "rgba(255,255,255,0)");
		ctx.fillStyle = g; ctx.fillRect(0, 0, s, s);
	});
}

function buildEffect(effect, spark) {
	const count = effect.kind === "Fire" ? 60 : effect.kind === "Sparkles" ? 18 : 34;
	const positions = new Float32Array(count * 3);
	const [px, py, pz] = effect.pos;
	const r = Math.max(effect.size[0], effect.size[1]) * 0.9;
	for (let i = 0; i < count; i++) {
		const a = Math.random() * Math.PI * 2;
		const d = r * (0.4 + Math.random() * 0.8);
		const up = effect.kind === "Fire" ? Math.random() * r * 1.6 : (Math.random() - 0.3) * r * 1.8;
		positions.set([px + Math.cos(a) * d * (effect.kind === "Fire" ? 0.5 : 1), py + up, pz + Math.sin(a) * d * (effect.kind === "Fire" ? 0.5 : 1)], i * 3);
	}
	const geo = new THREE.BufferGeometry();
	geo.setAttribute("position", new THREE.BufferAttribute(positions, 3));
	const color = srgb(effect.color);
	const mat = new THREE.PointsMaterial({
		color,
		map: spark,
		size: effect.kind === "Fire" ? 0.9 : effect.kind === "Sparkles" ? 0.45 : 0.6,
		transparent: true,
		depthWrite: false,
		blending: THREE.AdditiveBlending,
		toneMapped: false,
	});
	return new THREE.Points(geo, mat);
}

// opts: { scene json, textures: {surfaceIndex -> url}, {billboardIndex -> url}, camera: {pos, look, fov}, width, height, group (only render parts of a group), transparentBackground, silhouette }
export async function renderScene(canvas, data, opts) {
	const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: !!opts.transparentBackground, preserveDrawingBuffer: true });
	renderer.setPixelRatio(opts.pixelRatio || 1);
	renderer.setSize(opts.width, opts.height, false);
	renderer.toneMapping = THREE.ACESFilmicToneMapping;
	renderer.toneMappingExposure = 0.95;
	renderer.shadowMap.enabled = !opts.noShadows;
	renderer.shadowMap.type = THREE.PCFSoftShadowMap;

	const scene = new THREE.Scene();
	const theme = data.theme;
	if (!opts.transparentBackground) {
		const sky = srgb(theme.sky);
		const fog = srgb(theme.fog);
		scene.background = sky.clone().lerp(fog, 0.35);
		scene.fog = new THREE.Fog(fog, opts.fogNear ?? 220, opts.fogFar ?? 900);
	}
	const pmrem = new THREE.PMREMGenerator(renderer);
	scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
	scene.environmentIntensity = 0.55;

	const ambient = srgb(theme.ambient);
	const outdoor = srgb(theme.outdoor);
	scene.add(new THREE.HemisphereLight(outdoor, ambient.clone().multiplyScalar(0.5), 1.1));
	scene.add(new THREE.AmbientLight(ambient, 0.35));
	const sun = new THREE.DirectionalLight(srgb(theme.atmosphere).lerp(new THREE.Color(1, 1, 1), 0.6), 1.4);
	const look = new THREE.Vector3(...opts.camera.look);
	sun.position.copy(look).add(new THREE.Vector3(-90, 160, -60));
	sun.target.position.copy(look);
	sun.castShadow = !opts.noShadows;
	const shadowSpan = opts.shadowSpan || 90;
	Object.assign(sun.shadow.camera, { left: -shadowSpan, right: shadowSpan, top: shadowSpan, bottom: -shadowSpan, near: 1, far: 600 });
	sun.shadow.mapSize.set(2048, 2048);
	sun.shadow.bias = -0.0005;
	scene.add(sun, sun.target);

	const camPos = new THREE.Vector3(...opts.camera.pos);
	const include = (p) => opts.group == null || p.group === opts.group;

	const partsById = [];
	data.parts.forEach((p, i) => {
		if (!include(p)) return;
		const part = opts.silhouette ? { ...p, color: [15, 15, 20], material: "SmoothPlastic", transparency: 0 } : p;
		const obj = buildPart(part);
		partsById[i + 1] = p;
		scene.add(obj);
	});

	if (!opts.silhouette) {
		for (const [i, surface] of data.surfaces.entries()) {
			const part = partsById[surface.part];
			const url = opts.surfaceTextures?.[i];
			if (!part || !url) continue;
			const tex = await new THREE.TextureLoader().loadAsync(url);
			tex.colorSpace = THREE.SRGBColorSpace;
			tex.anisotropy = 8;
			scene.add(buildSurface(surface, part, tex));
		}
		if (!opts.noBillboards) {
			for (const [i, bb] of data.billboards.entries()) {
				const url = opts.billboardTextures?.[i];
				if (!url) continue;
				if (opts.group != null) continue;
				const dist = camPos.distanceTo(new THREE.Vector3(...bb.pos));
				if (dist > (bb.maxDistance || 1e9)) continue;
				const tex = await new THREE.TextureLoader().loadAsync(url);
				tex.colorSpace = THREE.SRGBColorSpace;
				const sprite = buildBillboard(bb, tex);
				if (bb.pixels) {
					// Constant screen size (Roblox offset-sized BillboardGui).
					const studsPerPixel = (2 * dist * Math.tan(((opts.camera.fov || 70) * Math.PI) / 360)) / opts.height;
					sprite.scale.set(bb.pixels[0] * studsPerPixel, bb.pixels[1] * studsPerPixel, 1);
				}
				scene.add(sprite);
			}
		}
		// Only the nearest lights matter for the shot; WebGL can't afford all of them.
		const lights = [...data.lights]
			.map((l) => ({ ...l, d: camPos.distanceTo(new THREE.Vector3(...l.pos)) + new THREE.Vector3(...l.pos).distanceTo(look) }))
			.sort((a, b) => a.d - b.d)
			.slice(0, opts.maxLights ?? 8);
		for (const l of lights) {
			const light = new THREE.PointLight(srgb(l.color), l.brightness * (l.kind === "SpotLight" ? 5 : 7), l.range * 1.3, 1.2);
			light.position.set(...l.pos);
			if (l.kind === "SpotLight") light.position.y -= 1;
			scene.add(light);
		}
		// Beams (e.g. the tutorial guide) as glowing tubes.
		for (const beam of data.beams || []) {
			const a = new THREE.Vector3(...beam.from);
			const b = new THREE.Vector3(...beam.to);
			const curve = new THREE.LineCurve3(a, b);
			const radius = ((beam.width0 || 1) + (beam.width1 || 1)) / 8;
			const tube = new THREE.Mesh(
				new THREE.TubeGeometry(curve, 1, radius, 10, false),
				new THREE.MeshBasicMaterial({ color: srgb(beam.color), transparent: true, opacity: 0.8, toneMapped: false, depthWrite: false }),
			);
			tube.renderOrder = 4;
			scene.add(tube);
		}
		const spark = sparkTexture();
		for (const effect of data.effects) {
			if (camPos.distanceTo(new THREE.Vector3(...effect.pos)) > 160) continue;
			scene.add(buildEffect(effect, spark));
		}
	}

	const camera = new THREE.PerspectiveCamera(opts.camera.fov || 70, opts.width / opts.height, 0.3, 3000);
	camera.position.copy(camPos);
	camera.lookAt(look);

	if (opts.noBloom) {
		renderer.render(scene, camera);
	} else {
		const composer = new EffectComposer(renderer);
		composer.setPixelRatio(opts.pixelRatio || 1);
		composer.setSize(opts.width, opts.height);
		composer.addPass(new RenderPass(scene, camera));
		composer.addPass(new UnrealBloomPass(new THREE.Vector2(opts.width, opts.height), 0.2 + (theme.bloom || 0.5) * 0.2, 0.4, 0.94));
		composer.addPass(new OutputPass());
		composer.render();
	}
	return renderer;
}

// Helpers for camera placement in plot-local space.
export function plotPoint(plotCf, x, y, z) {
	const v = new THREE.Vector3(x, y, z).applyMatrix4(cframeMatrix(plotCf));
	return [v.x, v.y, v.z];
}
