// Drives headless Chromium to turn the exported preview data into screenshots.
//
//   node preview/render/shoot.mjs [chad]
//
// Steps per variant: bake every SurfaceGui/BillboardGui to a PNG texture,
// render the 25 unit thumbnails (for the Index / reward UI), then render each
// shot (3D scene + real UI overlay) to preview/screenshots/<variant>/*.png.

import { chromium } from "playwright-core";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "out");
const SHOTS = join(ROOT, "screenshots");
const CHROME = process.env.CHROME || "/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell";
const variants = process.argv.slice(2).length ? process.argv.slice(2) : ["chad"];

// --- static server ------------------------------------------------------------------
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json", ".png": "image/png", ".ttf": "font/ttf", ".glb": "model/gltf-binary" };
// Uploaded Blender art (assets/pins.json) is drawn from the local files it was uploaded from:
// /asset-index.json maps image asset ids to their source PNGs (served from the game root under
// /game/art/ and /game/assets/) and mesh ids to preview/web/models/<key with / as __>.glb when present.
const GAME = resolve(ROOT, "..");
const GAME_DIRS = ["art", "assets"].map((d) => join(GAME, d) + "/");
function assetIndex() {
	const index = { images: {}, meshes: {} };
	let pins = {};
	try {
		pins = JSON.parse(readFileSync(join(GAME, "assets", "pins.json"), "utf8")).pins || {};
	} catch {}
	for (const [key, pin] of Object.entries(pins)) {
		if (!pin || !pin.assetId) continue;
		if (pin.kind === "Image" && pin.source && existsSync(join(GAME, pin.source))) {
			index.images[String(pin.assetId)] = "/game/" + pin.source.split("/").map(encodeURIComponent).join("/");
		} else if (pin.kind === "Model" && pin.meshId) {
			const id = String(pin.meshId).match(/(\d+)\s*$/)?.[1];
			const glb = key.replaceAll("/", "__") + ".glb";
			if (id) index.meshes[id] = { key, glb: existsSync(join(ROOT, "web", "models", glb)) ? `/web/models/${glb}` : null };
		}
	}
	return index;
}

const server = createServer((req, res) => {
	const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname);
	if (pathname === "/asset-index.json") {
		res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(assetIndex()));
		return;
	}
	const fromGame = pathname.startsWith("/game/");
	const path = fromGame ? join(GAME, pathname.slice("/game/".length)) : join(ROOT, pathname);
	const allowed = fromGame ? GAME_DIRS.some((d) => path.startsWith(d)) : path.startsWith(ROOT);
	if (!allowed || !existsSync(path)) {
		res.writeHead(404).end();
		return;
	}
	res.writeHead(200, { "content-type": TYPES[extname(path)] || "application/octet-stream" });
	res.end(readFileSync(path));
});
await new Promise((r) => server.listen(0, r));
const BASE = `http://127.0.0.1:${server.address().port}`;

// Lune encodes empty tables as {}; make every list field a real array.
function normalize(value) {
	if (Array.isArray(value)) return value.map(normalize);
	if (value && typeof value === "object") {
		const out = {};
		for (const [k, v] of Object.entries(value)) {
			const isListKey = k === "children" || k === "parts" || k === "surfaces" || k === "billboards" || k === "lights" || k === "effects" || k === "beams" || k === "decals";
			out[k] = isListKey && !Array.isArray(v) ? [] : normalize(v);
		}
		return out;
	}
	return value;
}
const readJson = (file) => normalize(JSON.parse(readFileSync(file, "utf8")));

// --- small CFrame helpers -------------------------------------------------------------
function toWorld(cf, [x, y, z]) {
	const [px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22] = cf;
	return [px + r00 * x + r01 * y + r02 * z, py + r10 * x + r11 * y + r12 * z, pz + r20 * x + r21 * y + r22 * z];
}

const FACE_DIMS = {
	Front: (s) => [s[0], s[1]],
	Back: (s) => [s[0], s[1]],
	Right: (s) => [s[2], s[1]],
	Left: (s) => [s[2], s[1]],
	Top: (s) => [s[0], s[2]],
	Bottom: (s) => [s[0], s[2]],
};

function surfacePx(surface, part) {
	const [w, h] = (FACE_DIMS[surface.face] || FACE_DIMS.Front)(part.size);
	if (surface.sizing === "PixelsPerStud") return [Math.round(w * surface.pixelsPerStud), Math.round(h * surface.pixelsPerStud)];
	return surface.canvas;
}

const BILLBOARD_PX_PER_STUD = 48;

// --- browser ---------------------------------------------------------------------------
const browser = await chromium.launch({
	executablePath: CHROME,
	args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"],
});

async function newPage(scale) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: scale });
	page.on("pageerror", (e) => console.error("[page error]", e.message));
	page.on("console", (m) => {
		if (m.type() === "error") console.error("[console]", m.text());
	});
	await page.goto(`${BASE}/web/stage.html`);
	await page.waitForFunction(() => typeof window.renderShot === "function");
	return page;
}

async function bakeTextures(page, variant, sceneName, scene) {
	const texDir = join(OUT, variant, "tex");
	mkdirSync(texDir, { recursive: true });
	const result = { surfaces: {}, billboards: {} };
	const jobs = [];
	scene.surfaces.forEach((s, i) => {
		const part = scene.parts[s.part - 1];
		if (!part) return;
		const [w, h] = surfacePx(s, part);
		if (w < 4 || h < 4) return;
		jobs.push({ kind: "surfaces", i, gui: s.gui, w, h });
	});
	scene.billboards.forEach((b, i) => {
		const w = Math.round(b.size[0] * BILLBOARD_PX_PER_STUD);
		const h = Math.round(b.size[1] * BILLBOARD_PX_PER_STUD);
		jobs.push({ kind: "billboards", i, gui: b.gui, w, h });
	});
	let baked = 0;
	// Cached bakes are keyed on the pinned images too, so a new upload re-bakes the GUIs that show it.
	const pinnedImages = JSON.stringify(assetIndex().images);
	for (const job of jobs) {
		const hasContent = JSON.stringify(job.gui).includes('"text":"') || JSON.stringify(job.gui).includes('"class":"Frame"') || JSON.stringify(job.gui).includes("Image");
		const key = createHash("sha1").update(JSON.stringify(JSON.stringify(job.gui).includes("rbxassetid") ? [job.gui, job.w, job.h, pinnedImages] : [job.gui, job.w, job.h])).digest("hex").slice(0, 16);
		const file = join(texDir, key + ".png");
		if (!existsSync(file)) {
			// Skip labels whose every text is empty (unowned plots).
			const texts = [];
			const walk = (n) => {
				if (n.text) texts.push(n.text);
				(n.children || []).forEach(walk);
			};
			walk(job.gui);
			const onlyText = !JSON.stringify(job.gui).includes('"class":"Frame"') && !JSON.stringify(job.gui).includes("Image");
			if (onlyText && texts.every((t) => t.trim() === "")) continue;
			if (!hasContent) continue;
			await page.evaluate(([gui, w, h]) => window.bakeGui(gui, w, h), [job.gui, job.w, job.h]);
			const handle = await page.$("#bake");
			await handle.screenshot({ path: file, omitBackground: true });
			baked++;
		}
		result[job.kind][job.i] = `/out/${variant}/tex/${key}.png`;
	}
	await page.evaluate(() => window.clearBake());
	console.log(`  ${sceneName}: ${jobs.length} gui textures (${baked} newly baked)`);
	return result;
}

async function renderThumbs(page, variant, showcase) {
	const dir = join(OUT, variant, "thumbs");
	mkdirSync(dir, { recursive: true });
	const map = {};
	for (let tier = 1; tier <= 25; tier++) {
		const parts = showcase.parts.filter((p) => p.group === tier);
		let minX = Infinity, minY = Infinity, minZ = Infinity, maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity;
		for (const p of parts) {
			const [x, y, z] = p.cf;
			const r = Math.max(...p.size) / 2;
			minX = Math.min(minX, x - r); maxX = Math.max(maxX, x + r);
			minY = Math.min(minY, y - p.size[1] / 2); maxY = Math.max(maxY, y + p.size[1] / 2);
			minZ = Math.min(minZ, z - r); maxZ = Math.max(maxZ, z + r);
		}
		const feet = [(minX + maxX) / 2, minY, (minZ + maxZ) / 2];
		const h = maxY - minY;
		// Same framing as Kit.unitViewport in the game.
		const camera = { pos: [feet[0] + h * 0.35, feet[1] + h * 0.62, feet[2] - h * 1.75], look: [feet[0], feet[1] + h * 0.5, feet[2]], fov: 40 };
		for (const sil of [0, 1]) {
			const file = join(dir, `${tier}_${sil}.png`);
			map[`thumb:${variant}:${tier}:${sil}`] = `/out/${variant}/thumbs/${tier}_${sil}.png`;
			// REUSE_THUMBS=1 skips re-rendering existing thumbnails (fast UI iteration).
			if (process.env.REUSE_THUMBS && existsSync(file)) continue;
			await page.evaluate(([scene, group, s, cam]) => window.renderThumb(scene, group, s === 1, cam, 320), [showcase, tier, sil, camera]);
			const handle = await page.$("#thumb");
			await handle.screenshot({ path: file, omitBackground: true });
			map[`thumb:${variant}:${tier}:${sil}`] = `/out/${variant}/thumbs/${tier}_${sil}.png`;
		}
	}
	console.log("  thumbnails: 50");
	return map;
}

function shotList(world) {
	const plot = world.plots[0];
	const P = (x, y, z) => toWorld(plot, [x, y, z]);
	// Behind the main player, who wades through the orb pool toward the bleachers.
	const play = { pos: P(-5, 21, -31), look: P(0, 2, 17), fov: 58 };
	// The fresh tutorial player owns plot 4.
	const fresh = world.plots[3];
	const F = (x, y, z) => toWorld(fresh, [x, y, z]);
	const tutorial = { pos: F(-4, 20, -36), look: F(12, 1, 8), fov: 56 };
	return [
		{ name: "01-overview", scene: "world", gui: "none", camera: { pos: [-24, 180, -235], look: [0, 0, 30], fov: 55 }, extra: { shadowSpan: 320 } },
		{ name: "02-your-plot", scene: "world", gui: "none", camera: { pos: P(0, 50, -68), look: P(0, 0, 8), fov: 60 }, extra: { shadowSpan: 120 } },
		{ name: "03-gameplay-hud", scene: "world", gui: "hud", camera: play },
		{ name: "04-shop", scene: "world", gui: "shop", camera: play },
		{ name: "05-index", scene: "world", gui: "index", camera: play },
		{ name: "06-ranking", scene: "world", gui: "ranking", camera: play },
		{ name: "07-new-unit-reward", scene: "world", gui: "reward", camera: play },
		{ name: "08-holding-crate", scene: "world_held", gui: "crate", camera: { pos: P(2, 9, -36), look: P(16, 2, -14), fov: 58 } },
		{ name: "09-settings", scene: "world", gui: "settings", camera: play },
		{ name: "10-all-25-tiers", scene: "showcase", gui: "none", camera: { pos: [0, 23, 1000 - 61], look: [0, 7.5, 1004], fov: 56 }, extra: { shadowSpan: 80 } },
		{ name: "11-tutorial", scene: "world_tutorial", gui: "tutorial", camera: tutorial },
		{ name: "12-tutorial-complete", scene: "world_tutorial", gui: "tutorial_done", camera: tutorial },
		{ name: "13-loading-screen", scene: "world", gui: "loading", camera: play },
		{ name: "14-offline-earnings", scene: "world", gui: "offline", camera: play },
		{ name: "15-shop-premium", scene: "world", gui: "shop_gems", camera: play },
		// Close-ups for art review (no UI).
		{ name: "16-pen", scene: "world", gui: "none", camera: { pos: P(19, 11, -9), look: P(0, 2, 15), fov: 55 }, extra: { shadowSpan: 90 } },
		{ name: "17-stage", scene: "world", gui: "none", camera: { pos: P(0, 13, 1), look: P(0, 8, 32), fov: 62 }, extra: { shadowSpan: 90 } },
		{ name: "18-machines", scene: "world", gui: "none", camera: { pos: P(-4, 14, -30), look: P(-34, 3, -8), fov: 58 }, extra: { shadowSpan: 90 } },
		{ name: "19-entrance", scene: "world", gui: "none", camera: { pos: P(10, 9, -62), look: P(0, 6, -20), fov: 58 }, extra: { shadowSpan: 120 } },
		{ name: "20-hub", scene: "world", gui: "none", camera: { pos: [22, 26, -58], look: [0, 8, 0], fov: 58 }, extra: { shadowSpan: 160 } },
		{ name: "21-shop-cosmetics", scene: "world", gui: "shop_cosmetics", camera: play },
		{ name: "22-shop-cash", scene: "world", gui: "shop_cash", camera: play },
		{ name: "23-shop-aura", scene: "world", gui: "shop_aura", camera: play },
	];
}

for (const variant of variants) {
	console.log(`== ${variant}`);
	const load = (name) => readJson(join(OUT, variant, name + ".json"));
	const scenes = { world: load("world"), world_held: load("world_held"), world_tutorial: load("world_tutorial"), showcase: load("showcase") };

	const bakePage = await newPage(2);
	const textures = {};
	for (const [name, scene] of Object.entries(scenes)) textures[name] = await bakeTextures(bakePage, variant, name, scene);
	await bakePage.close();

	const thumbPage = await newPage(1);
	const thumbs = await renderThumbs(thumbPage, variant, scenes.showcase);
	await thumbPage.close();

	const shotDir = join(SHOTS, variant);
	mkdirSync(shotDir, { recursive: true });
	const only = process.env.ONLY ? process.env.ONLY.split(",") : null;
	for (const shot of shotList(scenes.world)) {
		if (only && !only.some((o) => shot.name.includes(o))) continue;
		const page = await newPage(1.5);
		await page.evaluate((map) => window.setThumbs(map), thumbs);
		const gui = shot.gui === "none" ? null : readJson(join(OUT, variant, "gui", shot.gui + ".json"));
		const started = Date.now();
		await page.evaluate(([scene, tex, cam, g, extra]) => window.renderShot(scene, tex, cam, g, extra), [
			scenes[shot.scene],
			textures[shot.scene],
			shot.camera,
			gui,
			shot.extra || {},
		]);
		const file = join(shotDir, shot.name + ".png");
		await page.screenshot({ path: file, clip: { x: 0, y: 0, width: 1280, height: 720 } });
		await page.close();
		console.log(`  ${shot.name} (${((Date.now() - started) / 1000).toFixed(1)}s)`);
	}
}

await browser.close();
server.close();
