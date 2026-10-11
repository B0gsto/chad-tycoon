/*
 * gui-renderer.js — draws an exported Roblox GUI instance tree (see
 * preview/export/export.luau) as DOM, mimicking Roblox's own layout rules.
 *
 *   import { renderGui } from './gui-renderer.js';
 *   await renderGui(json, container, { imageResolver });
 *
 * The work happens in three passes:
 *   1. layout  — compute every element's absolute size/position the way the
 *                Roblox engine does (UDim2 scale+offset, AnchorPoint, UIPadding,
 *                UIListLayout, UIGridLayout, AutomaticSize, UIScale).
 *   2. text    — TextScaled font sizes are found by measuring real text in the
 *                browser (after fonts load), so wrapping matches what we draw.
 *   3. render  — one absolutely positioned <div> per GuiObject, nested like the
 *                instance tree so clipping/rotation/scale inherit naturally.
 *
 * No dependencies, no build step.
 */

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

// Local font files (relative to this module, i.e. preview/web/fonts/).
// `fallback`/`fallbackWeight` are used only if the file failed to load.
const FONT_FILES = {
	LuckiestGuy: { file: 'LuckiestGuy-Regular.ttf', fallback: '"Arial Black", Impact', fallbackWeight: 900 },
	FredokaOne: { file: 'FredokaOne-Regular.ttf', fallback: '"Arial Rounded MT Bold", Arial', fallbackWeight: 700 },
	Bangers: { file: 'Bangers-Regular.ttf', fallback: 'Impact, "Arial Narrow"', fallbackWeight: 700 },
	Michroma: { file: 'Michroma-Regular.ttf', fallback: 'Arial', fallbackWeight: 400 },
	Montserrat: { file: 'Montserrat-Bold.ttf', fallback: 'Arial', fallbackWeight: 700 },
	RobotoMono: { file: 'RobotoMono-Bold.ttf', fallback: 'monospace', fallbackWeight: 700 },
};

// Colour emoji are drawn with the system emoji font. The face is limited to
// emoji code points and listed FIRST in every stack, so emoji are always in
// colour (as in Roblox) while ordinary punctuation/digits keep the game font.
const EMOJI_FAMILY = 'RbxEmoji';
const EMOJI_RANGE =
	'U+231A-231B, U+23E9-23F3, U+23F8-23FA, U+24C2, U+25AA-25AB, U+25B6, U+25C0, U+25FB-25FE, ' +
	'U+2600-27BF, U+2934-2935, U+2B05-2B07, U+2B1B-2B1C, U+2B50, U+2B55, U+3030, U+303D, U+3297, ' +
	'U+3299, U+200D, U+20E3, U+FE0F, U+1F000-1FAFF, U+E0020-E007F';

const fontState = {}; // key -> true (loaded) | false (missing)
let fontsPromise = null;

function ensureFonts(baseUrl) {
	if (fontsPromise) return fontsPromise;
	const base = baseUrl ? new URL(baseUrl, document.baseURI) : new URL('./fonts/', import.meta.url);
	const jobs = Object.entries(FONT_FILES).map(async ([key, def]) => {
		try {
			const face = new FontFace(`RbxFont-${key}`, `url("${new URL(def.file, base).href}")`);
			await face.load();
			document.fonts.add(face);
			fontState[key] = true;
		} catch {
			fontState[key] = false; // missing file: fall back to system fonts
		}
	});
	jobs.push(
		(async () => {
			try {
				const face = new FontFace(
					EMOJI_FAMILY,
					'local("Noto Color Emoji"), local("NotoColorEmoji"), local("Apple Color Emoji"), local("Segoe UI Emoji")',
					{ unicodeRange: EMOJI_RANGE },
				);
				await face.load();
				document.fonts.add(face);
			} catch {
				/* no local emoji font: the trailing "Noto Color Emoji" fallback still applies */
			}
		})(),
	);
	fontsPromise = Promise.all(jobs);
	return fontsPromise;
}

// Maps a Roblox font name (Enum.Font name, "Enum.Font.X", or a FontFace asset
// path like "rbxasset://fonts/families/LuckiestGuy.json") to a local face key.
function fontKeyFor(name) {
	const n = String(name || '')
		.replace(/^Enum\.Font\./, '')
		.replace(/^.*\//, '')
		.replace(/\.json$/i, '');
	if (/^LuckiestGuy/i.test(n)) return ['LuckiestGuy', n];
	if (/^Fredoka/i.test(n)) return ['FredokaOne', n];
	if (/^Bangers/i.test(n)) return ['Bangers', n];
	if (/^Michroma/i.test(n)) return ['Michroma', n];
	if (/^(Gotham|Montserrat|BuilderSans)/i.test(n)) return ['Montserrat', n];
	if (/^(Code|RobotoMono)/i.test(n)) return ['RobotoMono', n];
	return [null, n];
}

/**
 * How Roblox's TextSize maps to CSS font-size:
 *  'lineHeight' (default) — TextSize is the line height (Roblox: TextBounds.Y
 *      = TextSize per line), so each font is scaled until its ascent+descent
 *      equals TextSize. Glyphs sit in the line exactly as the font's metrics say.
 *  'em' — TextSize is used directly as the CSS font-size.
 */
let textMetricsMode = 'lineHeight';
const emScaleCache = new Map();

function emScaleFor(metricsFamily, weight) {
	if (textMetricsMode === 'em') return 1;
	const key = `${weight} ${metricsFamily}`;
	if (!emScaleCache.has(key)) {
		let scale = 1;
		try {
			const g = document.createElement('canvas').getContext('2d');
			g.font = `${weight} 100px ${metricsFamily}`;
			const m = g.measureText(' ');
			const lh = m.fontBoundingBoxAscent + m.fontBoundingBoxDescent;
			if (lh > 0) scale = Math.min(1.5, Math.max(0.5, 100 / lh));
		} catch {
			/* keep 1 */
		}
		emScaleCache.set(key, scale);
	}
	return emScaleCache.get(key);
}

/** Returns { family, weight, emScale } for a Roblox font name. */
function fontCss(name) {
	const [key, n] = fontKeyFor(name);
	const tail = 'sans-serif, "Noto Color Emoji"';
	let core;
	let weight;
	if (key) {
		const def = FONT_FILES[key];
		core = `"RbxFont-${key}", ${def.fallback}`;
		weight = fontState[key] !== false ? 400 : def.fallbackWeight;
	} else {
		core = /Mono|Code|Courier/i.test(n) ? 'monospace' : 'Arial';
		weight = /(Bold|Black|Heavy)/i.test(n) ? 700 : 400;
	}
	return { family: `"${EMOJI_FAMILY}", ${core}, ${tail}`, weight, emScale: emScaleFor(`${core}, sans-serif`, weight) };
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const num = (v, d) => (typeof v === 'number' && isFinite(v) ? v : d);
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const px = (v) => `${Math.round(v * 1000) / 1000}px`;
const udim = (u, size) => (u ? num(u[0], 0) * size + num(u[1], 0) : 0); // UDim
const udimX = udim; // UDim2 X component (first two entries)
const udimY = (u, size) => (u ? num(u[2], 0) * size + num(u[3], 0) : 0);

function rgba(c, alpha = 1) {
	const [r, g, b] = c || [0, 0, 0];
	return `rgba(${r | 0}, ${g | 0}, ${b | 0}, ${Math.round(clamp01(alpha) * 1000) / 1000})`;
}

function escapeHtml(s) {
	return String(s).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
}

const ALIGN_FLEX = { Left: 'flex-start', Top: 'flex-start', Center: 'center', Right: 'flex-end', Bottom: 'flex-end' };

function alignOffset(align, space, used) {
	if (align === 'Center') return (space - used) / 2;
	if (align === 'Right' || align === 'Bottom') return space - used;
	return 0;
}

const GUI_CLASSES = new Set([
	'Frame', 'TextLabel', 'TextButton', 'TextBox', 'ImageLabel', 'ImageButton',
	'ViewportFrame', 'ScrollingFrame', 'CanvasGroup', 'VideoFrame',
]);
const LAYER_CLASSES = new Set(['ScreenGui', 'SurfaceGui', 'BillboardGui', 'PlayerGui', 'StarterGui']);
const TEXT_CLASSES = new Set(['TextLabel', 'TextButton', 'TextBox']);
const IMAGE_CLASSES = new Set(['ImageLabel', 'ImageButton', 'ViewportFrame']);

// 'gui' = a GuiObject, 'layer' = a LayerCollector-ish root, 'folder' = transparent grouping.
function kindOf(node) {
	if (LAYER_CLASSES.has(node.class)) return 'layer';
	if (GUI_CLASSES.has(node.class) || Array.isArray(node.size)) return 'gui';
	return 'folder';
}

const isShown = (n) => n && n.visible !== false && n.enabled !== false;

// Lune's JSON encoder writes empty Luau tables as {} — treat those as [].
const arr = (v) => (Array.isArray(v) ? v : v && typeof v === 'object' ? Object.values(v) : []);

function isTextNode(n) {
	return TEXT_CLASSES.has(n.class) && typeof n.text === 'string';
}

// ---------------------------------------------------------------------------
// Rich text -> HTML
// ---------------------------------------------------------------------------

const RICH_TAGS = new Set(['font', 'b', 'i', 'u', 's', 'uc', 'uppercase', 'sc', 'smallcaps', 'stroke', 'mark']);
const RICH_TOKEN = /<!--[\s\S]*?-->|<(\/?)([a-zA-Z]+)((?:\s+[a-zA-Z]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>/g;

function decodeEntities(s) {
	return s.replace(/&(lt|gt|quot|apos|amp);/g, (_, e) => ({ lt: '<', gt: '>', quot: '"', apos: "'", amp: '&' })[e]);
}

function parseAttrs(src) {
	const out = {};
	for (const m of (src || '').matchAll(/([a-zA-Z]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
		out[m[1].toLowerCase()] = m[2] ?? m[3];
	}
	return out;
}

function safeColor(c) {
	if (!c) return null;
	c = c.trim();
	if (/^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test(c)) return c;
	if (/^rgb\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\)$/i.test(c)) return c;
	return null;
}

function richTagStyle(tag, a) {
	const st = [];
	switch (tag) {
		case 'b': st.push('font-weight:700'); break;
		case 'i': st.push('font-style:italic'); break;
		case 'u': st.push('text-decoration:underline'); break;
		case 's': st.push('text-decoration:line-through'); break;
		case 'uc': case 'uppercase': st.push('text-transform:uppercase'); break;
		case 'sc': case 'smallcaps': st.push('font-variant:small-caps'); break;
		case 'font': {
			const color = safeColor(a.color);
			if (color) st.push(`color:${color}`);
			// --rbx-em is the TextSize->font-size factor of the label's own font.
			if (a.size && isFinite(+a.size)) st.push(`font-size:calc(${+a.size}px * var(--rbx-em, 1))`);
			if (a.face || a.family) {
				const f = fontCss(a.face || a.family);
				st.push(`font-family:${f.family.replace(/"/g, "'")}`);
			}
			if (a.weight) {
				const w = { thin: 100, extralight: 200, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700, extrabold: 800, heavy: 900 }[a.weight.toLowerCase()] ?? +a.weight;
				if (w) st.push(`font-weight:${w}`);
			}
			if (a.transparency && isFinite(+a.transparency)) st.push(`opacity:${1 - clamp01(+a.transparency)}`);
			break;
		}
		case 'stroke': {
			const color = safeColor(a.color) || '#000000';
			const t = isFinite(+a.thickness) ? +a.thickness : 1;
			st.push(`-webkit-text-stroke:${2 * t}px ${color}`, 'paint-order:stroke fill');
			break;
		}
		case 'mark': {
			const color = safeColor(a.color) || '#FFFF00';
			const t = isFinite(+a.transparency) ? +a.transparency : 0;
			st.push(`background-color:${color}`);
			if (t) st.push(`background-color:color-mix(in srgb, ${color} ${Math.round((1 - t) * 100)}%, transparent)`);
			break;
		}
	}
	return st.join(';');
}

/** Converts a Text value to safe HTML. Newlines stay as \n (white-space: pre*). */
function textToHtml(text, rich) {
	if (!rich) return escapeHtml(text);
	let out = '';
	let last = 0;
	const stack = [];
	for (const m of text.matchAll(RICH_TOKEN)) {
		out += escapeHtml(decodeEntities(text.slice(last, m.index)));
		last = m.index + m[0].length;
		if (m[0].startsWith('<!--')) continue;
		const closing = m[1] === '/';
		const tag = m[2].toLowerCase();
		if (tag === 'br') {
			out += '\n';
			continue;
		}
		if (!RICH_TAGS.has(tag)) {
			out += escapeHtml(m[0]); // unknown tag: shown literally
			continue;
		}
		if (closing) {
			const idx = stack.lastIndexOf(tag);
			if (idx >= 0) {
				while (stack.length > idx) {
					stack.pop();
					out += '</span>';
				}
			}
			continue;
		}
		if (m[4] === '/') continue; // self-closing formatting tag: no-op
		stack.push(tag);
		out += `<span style="${richTagStyle(tag, parseAttrs(m[3]))}">`;
	}
	out += escapeHtml(decodeEntities(text.slice(last)));
	out += '</span>'.repeat(stack.length);
	return out;
}

// ---------------------------------------------------------------------------
// Text measurement
// ---------------------------------------------------------------------------

/**
 * Hidden off-screen element used to measure text exactly as it will be drawn.
 * Roblox's TextSize is the line height in pixels, and lines are stacked at
 * TextSize * LineHeight, so we draw with font-size = line-height = TextSize.
 */
class TextMeasurer {
	constructor() {
		this.el = document.createElement('div');
		this.el.setAttribute('aria-hidden', 'true');
		Object.assign(this.el.style, {
			position: 'absolute', left: '-100000px', top: '0', visibility: 'hidden',
			pointerEvents: 'none', overflowWrap: 'normal', wordBreak: 'normal',
		});
		this.span = document.createElement('span');
		this.el.appendChild(this.span);
		document.body.appendChild(this.el);
		this.html = null;
	}

	/**
	 * width = null measures unconstrained (no wrapping except at \n) and
	 * returns the natural width. With a width, text wraps at word boundaries
	 * and `w` is the scroll width: it exceeds `width` only when a word does
	 * not fit (hanging spaces at wrap points don't count, as in Roblox).
	 * Returns { w, h }.
	 */
	measure(html, font, size, lineHeight, width) {
		const s = this.el.style;
		s.fontFamily = font.family;
		s.fontWeight = String(font.weight);
		s.fontSize = px(size * font.emScale);
		s.setProperty('--rbx-em', String(font.emScale));
		s.lineHeight = px(size * lineHeight);
		if (width == null) {
			s.width = 'max-content';
			s.whiteSpace = 'pre';
		} else {
			s.width = px(Math.max(0, width));
			s.whiteSpace = 'pre-wrap';
		}
		if (this.html !== html) {
			this.span.innerHTML = html;
			this.html = html;
		}
		const rect = this.el.getBoundingClientRect();
		// scrollWidth is an integer; >= the fractional width means "fits".
		const w = width == null ? rect.width : this.el.scrollWidth > Math.ceil(width) ? this.el.scrollWidth : Math.min(this.el.scrollWidth, width);
		return { w, h: rect.height };
	}

	dispose() {
		this.el.remove();
	}
}

function textProps(node) {
	return {
		font: fontCss(node.font),
		size: num(node.textSize, 14),
		lineHeight: num(node.lineHeight, 1),
		html: textToHtml(node.text ?? '', !!node.richText),
	};
}

// ---------------------------------------------------------------------------
// Layout pass
// ---------------------------------------------------------------------------

/*
 * A "box" mirrors one node:
 *   { node, kind, w, h,             unscaled AbsoluteSize
 *     left, top,                    DOM position inside the parent's content element
 *     vx, vy, vw, vh,               visual rect (after UIScale) inside the parent
 *     scale, pad:{t,b,l,r}, children:[box], canvas?:{w,h}, contentScale?, fontSize? }
 */

function paddingOf(node, w, h) {
	const p = node.padding;
	if (!p) return { t: 0, b: 0, l: 0, r: 0 };
	return { t: udim(p[0], h), b: udim(p[1], h), l: udim(p[2], w), r: udim(p[3], w) };
}

function measureNode(node, cw, ch, ctx, forced) {
	const kind = kindOf(node);
	const box = { node, kind, children: [], scale: 1 };
	if (kind === 'layer') {
		// LayerCollectors fill the viewport; a ScreenGui that doesn't ignore the
		// GUI inset starts below Roblox's top bar.
		box.inset = node.class === 'ScreenGui' && node.ignoreGuiInset !== true ? ctx.guiInset : 0;
		box.w = ctx.vw;
		box.h = ctx.vh - box.inset;
		// A UIScale under a ScreenGui scales all its content from the top-left.
		box.contentScale = num(node.scale, 1) || 1;
	} else if (kind === 'folder') {
		box.w = cw;
		box.h = ch;
	} else {
		box.scale = num(node.scale, 1);
		if (forced) [box.w, box.h] = forced;
		else {
			box.w = udimX(node.size, cw);
			box.h = udimY(node.size, ch);
		}
	}
	layoutChildren(box, ctx);

	// AutomaticSize: grow (never shrink) to fit content, then lay out again so
	// scale-sized children see the final size.
	const auto = kind === 'gui' ? node.automaticSize || 'None' : 'None';
	if (auto !== 'None' && !forced) {
		const ext = contentExtent(box, ctx);
		const nw = auto.includes('X') ? Math.max(box.w, ext.w) : box.w;
		const nh = auto.includes('Y') ? Math.max(box.h, ext.h) : box.h;
		if (nw !== box.w || nh !== box.h) {
			box.w = nw;
			box.h = nh;
			layoutChildren(box, ctx);
		}
	}
	return box;
}

// Size of everything inside the box (children + own text), padding included.
function contentExtent(box, ctx) {
	let { w, h } = box.layoutExt;
	const n = box.node;
	if (isTextNode(n) && !n.textScaled && n.text) {
		const tp = textProps(n);
		const autoX = (n.automaticSize || '').includes('X');
		const width = autoX || !n.textWrapped ? null : box.w - box.pad.l - box.pad.r;
		const m = ctx.measurer.measure(tp.html, tp.font, tp.size, tp.lineHeight, width);
		w = Math.max(w, m.w + box.pad.l + box.pad.r);
		h = Math.max(h, m.h + box.pad.t + box.pad.b);
	}
	return { w, h };
}

// Positions a child so that its *visual* (post-UIScale) top-left lands at
// (vx, vy). UIScale scales around the anchor point.
function placeVisual(cb, vx, vy) {
	const [ax, ay] = cb.node.anchor || [0, 0];
	cb.vw = cb.w * cb.scale;
	cb.vh = cb.h * cb.scale;
	cb.vx = vx;
	cb.vy = vy;
	cb.left = vx - num(ax, 0) * cb.w * (1 - cb.scale);
	cb.top = vy - num(ay, 0) * cb.h * (1 - cb.scale);
}

function sortForLayout(kids, sort) {
	return kids
		.map((c, i) => ({ c, i }))
		.sort((a, b) => {
			if (sort === 'Name') {
				const an = String(a.c.name ?? ''), bn = String(b.c.name ?? '');
				return (an < bn ? -1 : an > bn ? 1 : 0) || a.i - b.i;
			}
			return num(a.c.layoutOrder, 0) - num(b.c.layoutOrder, 0) || a.i - b.i;
		})
		.map((e) => e.c);
}

function layoutChildren(box, ctx) {
	const n = box.node;
	let areaW = box.w;
	let areaH = box.h;
	if (box.contentScale && box.contentScale !== 1) {
		areaW /= box.contentScale;
		areaH /= box.contentScale;
	}
	const scrolling = n.class === 'ScrollingFrame';
	if (scrolling) {
		// Children of a ScrollingFrame live on the canvas. The canvas is never
		// smaller than the window (CanvasSize scale is relative to the window).
		const cs = n.canvasSize || [0, 0, 0, 0];
		areaW = Math.max(box.w, udimX(cs, box.w));
		areaH = Math.max(box.h, udimY(cs, box.h));
	}
	const pad = box.kind === 'gui' ? paddingOf(n, areaW, areaH) : { t: 0, b: 0, l: 0, r: 0 };
	box.pad = pad;
	const iw = areaW - pad.l - pad.r;
	const ih = areaH - pad.t - pad.b;

	const kids = arr(n.children).filter(isShown);
	const laidOut = [];
	const free = [];
	for (const c of kids) {
		if ((n.list || n.grid) && kindOf(c) === 'gui') laidOut.push(c);
		else free.push(c);
	}

	box.children = [];
	let ext = { w: pad.l + pad.r, h: pad.t + pad.b };
	if (n.grid) ext = layoutGrid(box, laidOut, n.grid, pad, iw, ih, ctx);
	else if (n.list) ext = layoutList(box, laidOut, n.list, pad, iw, ih, ctx);

	for (const c of free) {
		const kind = kindOf(c);
		if (kind === 'layer') {
			const cb = measureNode(c, iw, ih, ctx);
			placeVisual(cb, 0, cb.inset);
			box.children.push(cb);
			continue;
		}
		if (kind === 'folder') {
			const cb = measureNode(c, iw, ih, ctx);
			placeVisual(cb, pad.l, pad.t);
			box.children.push(cb);
			ext.w = Math.max(ext.w, cb.layoutExt.w + pad.l + pad.r);
			ext.h = Math.max(ext.h, cb.layoutExt.h + pad.t + pad.b);
			continue;
		}
		const cb = measureNode(c, iw, ih, ctx);
		const [ax, ay] = c.anchor || [0, 0];
		const x = pad.l + udimX(c.position, iw);
		const y = pad.t + udimY(c.position, ih);
		placeVisual(cb, x - num(ax, 0) * cb.w * cb.scale, y - num(ay, 0) * cb.h * cb.scale);
		box.children.push(cb);
		ext.w = Math.max(ext.w, cb.vx + cb.vw + pad.r);
		ext.h = Math.max(ext.h, cb.vy + cb.vh + pad.b);
	}
	box.layoutExt = ext;

	if (scrolling) {
		const acs = n.automaticCanvasSize ?? 'Y'; // the game's scrollers all use AutomaticCanvasSize Y
		box.canvas = {
			w: acs.includes('X') ? Math.max(areaW, ext.w) : areaW,
			h: acs.includes('Y') ? Math.max(areaH, ext.h) : areaH,
		};
	}
}

// UIListLayout: children stacked in sort order, ignoring Position/AnchorPoint.
function layoutList(box, kids, list, pad, iw, ih, ctx) {
	const vertical = list.fill !== 'Horizontal';
	const gap = vertical ? udim(list.padding, ih) : udim(list.padding, iw);
	const boxes = sortForLayout(kids, list.sort).map((c) => measureNode(c, iw, ih, ctx));
	let total = 0;
	let cross = 0;
	for (const cb of boxes) {
		total += vertical ? cb.h * cb.scale : cb.w * cb.scale;
		cross = Math.max(cross, vertical ? cb.w * cb.scale : cb.h * cb.scale);
	}
	total += gap * Math.max(0, boxes.length - 1);

	if (vertical) {
		let y = pad.t + alignOffset(list.vAlign, ih, total);
		for (const cb of boxes) {
			const vw = cb.w * cb.scale;
			placeVisual(cb, pad.l + alignOffset(list.hAlign, iw, vw), y);
			y += cb.h * cb.scale + gap;
			box.children.push(cb);
		}
		return { w: pad.l + cross + pad.r, h: pad.t + total + pad.b };
	}
	let x = pad.l + alignOffset(list.hAlign, iw, total);
	for (const cb of boxes) {
		const vh = cb.h * cb.scale;
		placeVisual(cb, x, pad.t + alignOffset(list.vAlign, ih, vh));
		x += cb.w * cb.scale + gap;
		box.children.push(cb);
	}
	return { w: pad.l + total + pad.r, h: pad.t + cross + pad.b };
}

// UIGridLayout: every child is forced to CellSize; fills rows (or columns)
// then wraps. Alignment moves the whole block of cells.
function layoutGrid(box, kids, grid, pad, iw, ih, ctx) {
	const cw = udimX(grid.cellSize, iw);
	const chh = udimY(grid.cellSize, ih);
	const gx = udimX(grid.cellPadding, iw);
	const gy = udimY(grid.cellPadding, ih);
	const sorted = sortForLayout(kids, grid.sort);
	const count = sorted.length;
	const horizontal = grid.fill !== 'Vertical';
	const maxCells = num(grid.maxCells, 0);

	const fit = (space, cell, gap) => (cell + gap > 0 ? Math.max(1, Math.floor((space + gap) / (cell + gap) + 1e-6)) : Math.max(1, count));
	let perLine = horizontal ? fit(iw, cw, gx) : fit(ih, chh, gy);
	if (maxCells > 0) perLine = Math.min(perLine, maxCells);
	const lines = count ? Math.ceil(count / perLine) : 0;
	const along = Math.min(count, perLine);
	const cols = horizontal ? along : lines;
	const rows = horizontal ? lines : along;
	const blockW = cols ? cols * cw + (cols - 1) * gx : 0;
	const blockH = rows ? rows * chh + (rows - 1) * gy : 0;
	const ox = pad.l + alignOffset(grid.hAlign, iw, blockW);
	const oy = pad.t + alignOffset(grid.vAlign, ih, blockH);

	sorted.forEach((c, i) => {
		const col = horizontal ? i % perLine : Math.floor(i / perLine);
		const row = horizontal ? Math.floor(i / perLine) : i % perLine;
		const cb = measureNode(c, iw, ih, ctx, [cw, chh]);
		placeVisual(cb, ox + col * (cw + gx), oy + row * (chh + gy));
		box.children.push(cb);
	});
	return { w: pad.l + blockW + pad.r, h: pad.t + blockH + pad.b };
}

// ---------------------------------------------------------------------------
// TextScaled pass
// ---------------------------------------------------------------------------

function fitText(box, ctx) {
	const n = box.node;
	if (box.kind === 'gui' && isTextNode(n)) {
		const tp = textProps(n);
		box.textProps = tp;
		box.fontSize = tp.size;
		if (n.textScaled && n.text) {
			const w = box.w - box.pad.l - box.pad.r;
			const h = box.h - box.pad.t - box.pad.b;
			let hi = 100;
			let lo = 1;
			const c = n.textSizeConstraint;
			if (c) {
				hi = Math.min(hi, num(c.max, 100));
				lo = Math.max(1, num(c.min, 1));
			}
			// Largest integer size whose wrapped text fits both dimensions.
			// Wrapping is only at word boundaries, so a long word forces it smaller.
			const fits = (s) => {
				const m = ctx.measurer.measure(tp.html, tp.font, s, tp.lineHeight, w);
				return m.w <= w + 0.01 && m.h <= h + 0.01;
			};
			let best = lo;
			let a = lo;
			let b = Math.max(lo, hi);
			if (w > 0 && h > 0) {
				while (a <= b) {
					const mid = (a + b) >> 1;
					if (fits(mid)) {
						best = mid;
						a = mid + 1;
					} else b = mid - 1;
				}
			}
			box.fontSize = best;
		}
	}
	for (const c of box.children) fitText(c, ctx);
}

// ---------------------------------------------------------------------------
// Render pass
// ---------------------------------------------------------------------------

function cornerRadius(node, w, h) {
	if (!node.corner) return 0;
	const m = Math.max(0, Math.min(w, h));
	return Math.max(0, Math.min(m / 2, num(node.corner[0], 0) * m + num(node.corner[1], 0)));
}

function interpolate(points, t, pick) {
	if (!points || !points.length) return null;
	if (t <= points[0][0]) return pick(points[0]);
	for (let i = 1; i < points.length; i++) {
		const p0 = points[i - 1];
		const p1 = points[i];
		if (t <= p1[0]) {
			const f = p1[0] === p0[0] ? 0 : (t - p0[0]) / (p1[0] - p0[0]);
			const a = pick(p0);
			const b = pick(p1);
			return a.map((v, k) => v + (b[k] - v) * f);
		}
	}
	return pick(points[points.length - 1]);
}

/**
 * CSS linear-gradient for a UIGradient applied over `base` colour/alpha.
 * Roblox multiplies the object's colour by the gradient colour, and its
 * Rotation is clockwise from left->right (CSS 90deg = left->right).
 */
function gradientCss(g, base, baseAlpha) {
	const stops = arr(g.stops).length ? [...arr(g.stops)].sort((a, b) => a[0] - b[0]) : [[0, 255, 255, 255], [1, 255, 255, 255]];
	const transp = arr(g.transparency).length ? [...arr(g.transparency)].sort((a, b) => a[0] - b[0]) : null;
	const times = new Set(stops.map((s) => s[0]));
	if (transp) transp.forEach((s) => times.add(s[0]));
	const parts = [...times]
		.sort((a, b) => a - b)
		.map((t) => {
			const c = interpolate(stops, t, (p) => [p[1], p[2], p[3]]);
			const tr = transp ? interpolate(transp, t, (p) => [p[1]])[0] : 0;
			const col = [0, 1, 2].map((k) => (c[k] * (base ? base[k] : 255)) / 255);
			return `${rgba(col, baseAlpha * (1 - tr))} ${Math.round(t * 10000) / 100}%`;
		});
	return `linear-gradient(${90 + num(g.rotation, 0)}deg, ${parts.join(', ')})`;
}

function div(cls) {
	const d = document.createElement('div');
	if (cls) d.className = cls;
	d.style.position = 'absolute';
	return d;
}

function zSorted(children) {
	// ZIndexBehavior.Sibling: higher ZIndex on top, ties keep instance order.
	// ScreenGuis use DisplayOrder.
	const key = (b) => (b.kind === 'layer' ? num(b.node.displayOrder, 0) : num(b.node.zindex, 1));
	return children.map((b, i) => ({ b, i })).sort((x, y) => key(x.b) - key(y.b) || x.i - y.i).map((e) => e.b);
}

function renderBox(box, parentEl, ctx) {
	const n = box.node;
	const el = div('rbx');
	el.dataset.class = n.class;
	if (n.name) el.dataset.name = n.name;
	const s = el.style;
	s.left = px(box.left);
	s.top = px(box.top);
	s.width = px(Math.max(0, box.w));
	s.height = px(Math.max(0, box.h));
	parentEl.appendChild(el);

	if (box.kind !== 'gui') {
		let content = el;
		if (box.contentScale && box.contentScale !== 1) {
			content = div('rbx-content');
			Object.assign(content.style, {
				left: '0', top: '0', width: px(box.w / box.contentScale), height: px(box.h / box.contentScale),
				transformOrigin: '0 0', transform: `scale(${box.contentScale})`,
			});
			el.appendChild(content);
		}
		for (const c of zSorted(box.children)) renderBox(c, content, ctx);
		return el;
	}

	const w = Math.max(0, box.w);
	const h = Math.max(0, box.h);
	const [ax, ay] = (n.anchor || [0, 0]).map((v) => num(v, 0));
	const rot = num(n.rotation, 0);
	const sc = box.scale;

	// UIScale scales around the anchor; Rotation turns around the (scaled) centre.
	if (rot || sc !== 1) {
		s.transformOrigin = `${ax * 100}% ${ay * 100}%`;
		const dx = (0.5 - ax) * w * sc;
		const dy = (0.5 - ay) * h * sc;
		const parts = [];
		if (rot) parts.push(`translate(${px(dx)}, ${px(dy)}) rotate(${rot}deg) translate(${px(-dx)}, ${px(-dy)})`);
		if (sc !== 1) parts.push(`scale(${sc})`);
		s.transform = parts.join(' ');
	}

	const radius = cornerRadius(n, w, h);
	if (radius) s.borderRadius = px(radius);

	// Background (multiplied by UIGradient if present).
	const bgAlpha = n.bg ? 1 - clamp01(num(n.bgTransparency, 0)) : 0;
	if (bgAlpha > 0) {
		if (n.gradient) s.backgroundImage = gradientCss(n.gradient, n.bg, bgAlpha);
		else s.backgroundColor = rgba(n.bg, bgAlpha);
	}

	// Legacy BorderSizePixel border (only if the exporter provides it).
	const borderSize = num(n.borderSize, 0);
	if (borderSize > 0 && bgAlpha > 0 && !n.corner) {
		s.boxShadow = `0 0 0 ${px(borderSize)} ${rgba(n.borderColor || [27, 42, 53], bgAlpha)}`;
	}

	// Image / ViewportFrame snapshot.
	if (IMAGE_CLASSES.has(n.class)) renderImage(box, el, radius, ctx);

	// UIStroke. Contextual mode on text objects outlines the glyphs (handled in
	// renderText); otherwise it is a border drawn outside the box. Roblox's
	// default LineJoinMode is Round, so even square boxes get rounded outer
	// corners of radius = thickness.
	const stroke = n.stroke;
	const textStroke = stroke && isTextNode(n) && stroke.mode !== 'Border';
	if (stroke && !textStroke && num(stroke.thickness, 0) > 0) {
		const t = num(stroke.thickness, 1);
		const sd = div('rbx-stroke');
		const strokeAlpha = 1 - clamp01(num(stroke.transparency, 0));
		Object.assign(sd.style, {
			left: px(-t), top: px(-t), width: px(w + 2 * t), height: px(h + 2 * t),
			boxSizing: 'border-box', borderRadius: px(radius + t), pointerEvents: 'none',
		});
		if (stroke.gradient) {
			// A UIGradient inside the stroke: paint the gradient and keep only the ring
			// (a border cannot carry a gradient and rounded corners at once).
			const ring = 'linear-gradient(#000 0 0)';
			Object.assign(sd.style, {
				padding: px(t), backgroundImage: gradientCss(stroke.gradient, stroke.color, strokeAlpha),
				webkitMask: `${ring} content-box, ${ring}`, webkitMaskComposite: 'xor', maskComposite: 'exclude',
			});
		} else {
			sd.style.border = `${px(t)} solid ${rgba(stroke.color, strokeAlpha)}`;
		}
		el.appendChild(sd);
	}

	// Content layer: holds text and children; clips when ClipsDescendants is set
	// (Roblox clips rectangularly and not at all under rotation; CanvasGroup
	// clips to its rounded shape).
	const content = div('rbx-content');
	Object.assign(content.style, { left: '0', top: '0', width: '100%', height: '100%' });
	const scrolling = n.class === 'ScrollingFrame';
	if (n.class === 'CanvasGroup') {
		content.style.overflow = 'hidden';
		if (radius) content.style.borderRadius = px(radius);
		const gt = num(n.groupTransparency, 0);
		if (gt) el.style.opacity = String(1 - clamp01(gt));
	} else if (scrolling || (n.clips && !rot)) {
		content.style.overflow = 'hidden';
	}
	el.appendChild(content);

	if (isTextNode(n)) renderText(box, content);

	let childParent = content;
	if (scrolling) {
		const canvas = div('rbx-canvas');
		const pos = n.canvasPosition || [0, 0];
		Object.assign(canvas.style, {
			left: px(-num(pos[0], 0)), top: px(-num(pos[1], 0)), width: px(box.canvas.w), height: px(box.canvas.h),
		});
		content.appendChild(canvas);
		childParent = canvas;
	}
	for (const c of zSorted(box.children)) renderBox(c, childParent, ctx);

	if (scrolling) renderScrollbar(box, el);
	return el;
}

function renderScrollbar(box, el) {
	const n = box.node;
	const thickness = num(n.scrollBarThickness, 8);
	const ch = box.canvas.h;
	if (thickness <= 0 || ch <= box.h + 0.5) return;
	const top = (num((n.canvasPosition || [0, 0])[1], 0) / ch) * box.h;
	const bar = div('rbx-scrollbar');
	const color = n.scrollBarColor || n.attributes?.scrollBarColor || [0, 0, 0];
	Object.assign(bar.style, {
		left: px(box.w - thickness), top: px(top), width: px(thickness), height: px((box.h * box.h) / ch),
		backgroundColor: rgba(color, 1 - clamp01(num(n.scrollBarTransparency, 0))),
		borderRadius: px(Math.min(thickness / 2, 3)), pointerEvents: 'none',
	});
	el.appendChild(bar);
}

const SCALE_FIT = { Stretch: 'fill', Fit: 'contain', Crop: 'cover', Tile: 'none', Slice: 'fill' };

function renderImage(box, el, radius, ctx) {
	const n = box.node;
	const image = typeof n.image === 'string' ? n.image : '';
	if (!image) return; // e.g. ViewportFrame without a snapshot: transparent
	const resolver = ctx.opts.imageResolver;
	let url = null;
	try {
		url = resolver ? resolver(image, n) : null;
	} catch (err) {
		console.warn('imageResolver failed for', image, err);
	}
	const transparency = clamp01(num(n.imageTransparency, 0));
	if (transparency >= 1) return;

	const placeholder = () => {
		const ph = div('rbx-image-placeholder');
		Object.assign(ph.style, {
			left: '0', top: '0', width: '100%', height: '100%', boxSizing: 'border-box',
			borderRadius: px(Math.max(radius, Math.min(10, Math.min(box.w, box.h) / 4))),
			background: 'rgba(255,255,255,0.14)', border: '2px dashed rgba(255,255,255,0.4)',
			opacity: String(1 - transparency),
		});
		return ph;
	};

	if (!url) {
		el.appendChild(placeholder());
		return;
	}
	const wrap = div('rbx-image');
	Object.assign(wrap.style, {
		left: '0', top: '0', width: '100%', height: '100%', overflow: 'hidden',
		borderRadius: radius ? px(radius) : '', opacity: String(1 - transparency),
	});
	if (Array.isArray(n.imageRect) && n.imageRect[2] > 0 && n.imageRect[3] > 0) {
		renderImageRect(box, wrap, url, ctx, placeholder);
		el.appendChild(wrap);
		return;
	}
	const img = document.createElement('img');
	img.src = url;
	img.alt = '';
	img.draggable = false;
	Object.assign(img.style, {
		position: 'absolute', left: '0', top: '0', width: '100%', height: '100%',
		objectFit: SCALE_FIT[n.scaleType] || 'contain', display: 'block',
	});
	wrap.appendChild(img);
	// ImageColor3 tint: multiply a colour layer masked to the image's alpha.
	const tint = n.imageColor;
	if (tint && (tint[0] < 255 || tint[1] < 255 || tint[2] < 255)) {
		const t = div('rbx-image-tint');
		const fit = SCALE_FIT[n.scaleType] || 'contain';
		const maskSize = fit === 'fill' ? '100% 100%' : fit === 'cover' ? 'cover' : 'contain';
		Object.assign(t.style, {
			left: '0', top: '0', width: '100%', height: '100%', backgroundColor: rgba(tint),
			mixBlendMode: 'multiply', maskImage: `url("${url}")`, webkitMaskImage: `url("${url}")`,
			maskSize, webkitMaskSize: maskSize, maskRepeat: 'no-repeat', webkitMaskRepeat: 'no-repeat',
			maskPosition: 'center', webkitMaskPosition: 'center',
		});
		wrap.appendChild(t);
	}
	el.appendChild(wrap);
	ctx.images.push({ img, onFail: () => wrap.replaceWith(placeholder()) });
}

// ImageRectOffset / ImageRectSize: only the [x, y, w, h] pixel rect of the image is shown, laid out by
// ScaleType as if it were the whole image. The rect's aspect is known up front; the full image's size
// is not, so the image (and its ImageColor3 tint mask) is positioned once it has decoded.
function renderImageRect(box, wrap, url, ctx, placeholder) {
	const n = box.node;
	const [rx, ry, rw, rh] = n.imageRect;
	const W = box.w, H = box.h;
	let sx = W / rw, sy = H / rh;
	if (n.scaleType === 'Fit') sx = sy = Math.min(W / rw, H / rh);
	else if (n.scaleType === 'Crop') sx = sy = Math.max(W / rw, H / rh);
	const dw = rw * sx, dh = rh * sy;
	const clip = div('rbx-image-rect');
	Object.assign(clip.style, { left: px((W - dw) / 2), top: px((H - dh) / 2), width: px(dw), height: px(dh), overflow: 'hidden' });
	const img = document.createElement('img');
	img.src = url;
	img.alt = '';
	img.draggable = false;
	Object.assign(img.style, { position: 'absolute', left: px(-rx * sx), top: px(-ry * sy), display: 'block', maxWidth: 'none' });
	clip.appendChild(img);
	const tint = n.imageColor;
	const tinted = tint && (tint[0] < 255 || tint[1] < 255 || tint[2] < 255);
	const t = tinted ? div('rbx-image-tint') : null;
	if (t) {
		Object.assign(t.style, {
			left: px(-rx * sx), top: px(-ry * sy), backgroundColor: rgba(tint), mixBlendMode: 'multiply',
			maskImage: `url("${url}")`, webkitMaskImage: `url("${url}")`, maskSize: '100% 100%', webkitMaskSize: '100% 100%',
			maskRepeat: 'no-repeat', webkitMaskRepeat: 'no-repeat',
		});
		clip.appendChild(t);
	}
	wrap.appendChild(clip);
	const onLoad = () => {
		const w = px(img.naturalWidth * sx), h = px(img.naturalHeight * sy);
		Object.assign(img.style, { width: w, height: h });
		if (t) Object.assign(t.style, { width: w, height: h });
	};
	ctx.images.push({ img, onLoad, onFail: () => wrap.replaceWith(placeholder()) });
}

function renderText(box, content) {
	const n = box.node;
	const tp = box.textProps;
	if (!n.text || !tp) return;
	const textAlpha = 1 - clamp01(num(n.textTransparency, 0));
	if (textAlpha <= 0) return;

	const wrap = !!(n.textScaled || n.textWrapped);
	const size = box.fontSize;
	const layer = div('rbx-text');
	Object.assign(layer.style, {
		left: px(box.pad.l), top: px(box.pad.t),
		width: px(Math.max(0, box.w - box.pad.l - box.pad.r)), height: px(Math.max(0, box.h - box.pad.t - box.pad.b)),
		display: 'flex', flexDirection: 'column',
		justifyContent: ALIGN_FLEX[n.yAlign] || 'center',
		// Wrapped text spans the full width; unwrapped text is a single block
		// aligned (and allowed to overflow) per TextXAlignment.
		alignItems: wrap ? 'stretch' : ALIGN_FLEX[n.xAlign] || 'center',
		pointerEvents: 'none',
	});

	const makeInner = () => {
		const inner = document.createElement('div');
		Object.assign(inner.style, {
			fontFamily: tp.font.family, fontWeight: String(tp.font.weight), fontSize: px(size * tp.font.emScale),
			lineHeight: px(size * tp.lineHeight), whiteSpace: wrap ? 'pre-wrap' : 'pre',
			overflowWrap: n.textScaled ? 'normal' : 'break-word',
			textAlign: { Left: 'left', Right: 'right' }[n.xAlign] || 'center',
			flex: 'none', width: wrap ? '100%' : 'max-content',
		});
		inner.style.setProperty('--rbx-em', String(tp.font.emScale));
		inner.innerHTML = tp.html;
		return inner;
	};

	// Stroke on the glyphs: UIStroke (Contextual) or legacy TextStroke.
	let strokeCss = null;
	const st = n.stroke;
	if (st && st.mode !== 'Border' && num(st.thickness, 0) > 0) {
		strokeCss = { width: num(st.thickness, 1), color: rgba(st.color, (1 - clamp01(num(st.transparency, 0))) * textAlpha) };
	} else if (n.textStrokeTransparency != null && n.textStrokeTransparency < 1) {
		strokeCss = { width: 1, color: rgba(n.textStrokeColor || [0, 0, 0], (1 - clamp01(n.textStrokeTransparency)) * textAlpha) };
	}

	const color = rgba(n.textColor || [0, 0, 0], textAlpha);
	if (n.gradient) {
		// UIGradient also tints text. The stroke goes on a separate layer
		// underneath; on top, the whole text area carries the gradient (so it
		// spans the label as in Roblox) clipped to the glyphs.
		if (strokeCss) {
			const under = layer.cloneNode(false);
			const si = makeInner();
			si.style.color = strokeCss.color;
			si.style.webkitTextStroke = `${px(strokeCss.width * 2)} ${strokeCss.color}`;
			under.appendChild(si);
			content.appendChild(under);
		}
		Object.assign(layer.style, {
			backgroundImage: gradientCss(n.gradient, n.textColor || [0, 0, 0], textAlpha),
			backgroundClip: 'text', webkitBackgroundClip: 'text', webkitTextFillColor: 'transparent',
		});
		layer.appendChild(makeInner());
	} else {
		const inner = makeInner();
		inner.style.color = color;
		if (strokeCss) {
			// Stroke is centred on the outline, so draw it twice as wide and paint
			// it before the fill: only the outer half remains visible.
			inner.style.webkitTextStroke = `${px(strokeCss.width * 2)} ${strokeCss.color}`;
			inner.style.paintOrder = 'stroke fill';
		}
		layer.appendChild(inner);
	}
	content.appendChild(layer);
}

function waitImages(entries, timeoutMs) {
	const each = entries.map(({ img, onFail, onLoad }) =>
		img.decode().then(
			() => onLoad?.(),
			() => {
				if (!img.complete || img.naturalWidth === 0) onFail();
				else onLoad?.();
			},
		),
	);
	return Promise.race([Promise.all(each), new Promise((r) => setTimeout(r, timeoutMs))]);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Renders an exported GUI tree into `container`.
 *
 * @param {{viewport:[number,number], root:object}} json
 * @param {HTMLElement} container  absolutely positioned, viewport-sized
 * @param {object} [opts]
 * @param {(image:string, node:object) => string|null} [opts.imageResolver]
 *        maps Image strings (e.g. "thumb:chad:12:0", "rbxassetid://…") to URLs
 * @param {number} [opts.guiInset=58]  top-bar inset applied to ScreenGuis that
 *        don't set ignoreGuiInset (Roblox default IgnoreGuiInset=false)
 * @param {string} [opts.fontBaseUrl]   override the fonts/ directory URL
 * @param {number} [opts.imageTimeout=8000]  ms to wait for images to decode
 * @param {'lineHeight'|'em'} [opts.textMetrics='lineHeight']  TextSize -> CSS
 *        font-size mapping (see textMetricsMode)
 * @returns {Promise<HTMLElement>} the root element, once fonts are loaded,
 *          text has been fitted and images have decoded (or timed out)
 */
export async function renderGui(json, container, opts = {}) {
	textMetricsMode = opts.textMetrics === 'em' ? 'em' : 'lineHeight';
	const [vw, vh] = json.viewport || [container.clientWidth, container.clientHeight];
	await ensureFonts(opts.fontBaseUrl);
	if (document.fonts && document.fonts.ready) await document.fonts.ready;

	const layer = div('rbx-gui');
	Object.assign(layer.style, { left: '0', top: '0', width: px(vw), height: px(vh), overflow: 'hidden' });
	if (!isShown(json.root)) {
		container.appendChild(layer);
		return layer;
	}

	const measurer = new TextMeasurer();
	const ctx = { vw, vh, measurer, guiInset: num(opts.guiInset, 58), opts, images: [] };
	try {
		// The root is laid out as a free child of a viewport-sized area.
		const fake = { class: 'Folder', children: [json.root] };
		const top = measureNode(fake, vw, vh, ctx);
		fitText(top, ctx);
		for (const c of zSorted(top.children)) renderBox(c, layer, ctx);
	} finally {
		measurer.dispose();
	}
	container.appendChild(layer);
	if (document.fonts && document.fonts.ready) await document.fonts.ready;
	await waitImages(ctx.images, num(opts.imageTimeout, 8000));
	return layer;
}
