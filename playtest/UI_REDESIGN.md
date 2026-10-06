> Historical working note from 2026-10-06. It no longer matches the game;
> see README.md for the current design.

# Chad Aura Tycoon: UI critique and redesign spec

Reviewed: `/tmp/chadreview-b7/ui/ui_sheet.jpg` (HUD, Shop passes, Shop cash, Index, Settings) at 1366x768,
against `reference/contact-sheet.jpg`. Code read: `Kit.luau`, `Hud.luau`, `Windows.luau`, `Popups.luau`,
`Tutorial.luau`, `Theme.luau`, `Main.client.luau` (`rescale`).

Top line: the user is right. Every element is built from the same "chunky sticker" recipe (saturated fill,
3 px black outline, white gloss strip, outlined LuckiestGuy caps), so nothing has rank, and the screen reads
as a pile of free-model buttons rather than a product. The bones are good (Kit is small and consistent, the
HUD is complete, windows/popups already have a lifecycle), so this is a re-skin plus a layout merge, not a
rewrite.

Note: the "settings" capture shows only the HUD; the Settings window either did not open or is captured
before its open tween. Re-capture after the redesign.

---

## 1. Why it reads as cheap

1. **No hierarchy.** The wallet, counter, gauge, tank, tutorial card, six menu buttons, promo, surge timer,
   gear, chips and every shop card all have the same weight: a 3 px black `UIStroke`, a rounded corner of
   12 to 22 px and a two-stop gradient. The eye has nowhere to land. In the reference, only two things are
   loud at any time (the money readout and the current call to action); everything else is a quiet dark
   surface.
2. **Rainbow menu.** The left rail is six different saturated hues (gold, violet, orange, green, teal, pink)
   plus a gold promo, on a gold/violet neon world. The one genuine CTA (2x cash) is the same gold as Shop
   and the wallet coin, so it is not a CTA.
3. **Outlined text everywhere.** `Kit.text` adds a black `UIStroke` to every label by default (1.2 to 3 px).
   White-with-black-outline on 13 px uppercase LuckiestGuy ("FRIENDS +0%", "PERMANENT", "changes in 18s",
   "about 5:00 of income") is unreadable and is the single strongest "2016 free model" signal.
4. **One font for every job.** LuckiestGuy is used for titles, body copy ("Converted cash goes straight to
   your wallet"), numbers ("$100.00K") and micro labels. It is a display face; it has no tabular figures,
   so money values do not scan, and at small sizes its uneven strokes turn to mud.
5. **Flat, glossy colour.** Button faces are a near-flat saturated fill with an 80 % transparent white
   rectangle on top (the "Shine" frame). That is the Web 2.0 gel-button look. Panels are a dark purple with
   a barely visible 7 %/14 % gradient and a black border on a dark purple world, so windows have no edge
   light and no shadow; they neither sit on the scene nor float above it.
6. **Emoji iconography.** 🛒 📖 🏆 🏠 🤝 🎁 ⚙️ 💰 💵 👥 render through the platform emoji font at
   inconsistent weights and in their own colour palette (Apple-style blue bag, brown box, grey gear).
   They are also the first thing a player sees. `Hud.luau` already builds a gear from frames
   (`GearIcon`/`Tooth`/`Ring`/`Hub`) and that one looks fine, which proves the point.
7. **Density and stacking.** The left column stacks wallet (122 px) + chips row + a 2x3 grid (76 px cells
   + 10 px gaps) + promo (74 px): about 500 px of the 720 px design height, all touching. Top centre stacks a
   counter capsule on top of a gauge panel (two separate floating boxes 8 px apart). With the tutorial card
   and the tank at the bottom there are 11 separate floating boxes on the HUD before any window opens.
   The reference HUD has four.
8. **Stickers and tilt.** Rotated pills ("PERMANENT" at -5°, "POPULAR"/"BEST VALUE" at 6°), a tilted
   medallion on every window header, and a header bar inset inside the panel (double frame). These are
   garnish on top of garnish.
9. **Shop cards fight each other.** The three pass cards are fully painted in three different colours with
   a button-styled title bar, and a green price button sits on a green card. The cash tab is six identical
   cards with the amount, the price and the sub-label all competing at the same weight. The reference uses
   dark cards, one icon, one title, one green price.
10. **Windows do not take over.** `Kit.window` has no backdrop; the HUD keeps full contrast behind the Shop
    (the tank capsule is visible through the bottom edge of the Shop in the capture). Modals in `Popups`
    do dim, so the two systems feel different.
11. **Motion is one trick.** Everything uses `Back` scale pops (open 0.86→1, hover 1.05, press 0.95). There
    is no fade, no slide, no idle shimmer on the CTA, no slide indicator on tabs. Windows pop like reward
    cards, so reward cards do not feel special.
12. **Mobile.** `Compact` only hides the chips row and the promo. The 76/84 px cells with 13 px labels,
    the 300 px wallet and the 336 px gauge do not change. On a 16:9 phone at the 1.15 touch scale the left
    rail and the top centre gauge overlap the Roblox top bar and each other.

---

## 2. Design direction

**Visual language: "neon gym, premium dark glass".** The world is already neon gold/violet, so the UI
must be quiet: graphite glass surfaces with a lit top rim, one gold accent, violet for Index/rizz,
green reserved for money and success, red reserved for close/danger. Depth comes from a soft drop
shadow and a rim light, not from black outlines. Text gets a soft shadow, never an outline, except
the three hero labels (window titles, reward card titles, money amount) which keep a 1.5 px dark stroke
tinted to the surface. Icons are built from shapes or crisp text glyphs, never emoji, on the HUD and in
windows (emoji may remain inside popup copy and the tutorial body).

### 2.1 Palette (exact Color3)

Add these to `Theme.Colors` and keep the old keys as aliases so nothing breaks.

| Role | Color3 | Notes |
|---|---|---|
| Ink (backdrops, shadows) | `rgb(12, 10, 20)` | window backdrop at 0.45 transparency |
| Surface (panel body) | `rgb(32, 28, 48)` | gradient top `rgb(38, 34, 56)` → bottom `rgb(24, 21, 38)` |
| SurfaceHi (cards, rail buttons) | `rgb(46, 41, 68)` | gradient `rgb(52, 47, 76)` → `rgb(40, 36, 60)` |
| Well (insets, scroll areas) | `rgb(18, 16, 28)` | flat |
| Edge (panel stroke) | `rgb(78, 70, 112)` | 1.5 px, with rim-light gradient (see 2.3) |
| Rim (top highlight) | `rgb(255, 255, 255)` | via stroke gradient, transparency 0.55 top → 0.95 bottom |
| Gold (primary / CTA) | `rgb(255, 198, 56)` | deep `rgb(206, 140, 14)`, light `rgb(255, 228, 136)` |
| Violet (secondary / Index / Rizz) | `rgb(150, 92, 255)` | deep `rgb(98, 52, 196)` |
| Cash green | `rgb(72, 224, 112)` | deep `rgb(30, 156, 68)`; money text `rgb(118, 240, 150)` |
| Rizz blue (gems) | `rgb(84, 198, 255)` | deep `rgb(32, 120, 196)` |
| Surge amber | `rgb(255, 150, 40)` | surge timer, surge bar |
| Danger | `rgb(255, 88, 88)` | close buttons, "bad" toasts |
| Text | `rgb(248, 246, 255)` | |
| TextDim | `rgb(170, 164, 196)` | descriptions, units |
| TextMute | `rgb(112, 106, 140)` | micro labels, version |
| Rarity | keep current values but desaturate 15 % (`color:Lerp(Surface, 0.15)`) for pill backgrounds; full value for text | |

`Theme.Colors.Panel`, `PanelLight`, `PanelDark`, `Stroke`, `Primary`, `Secondary`, `Good`, `Bad` must stay
defined (map Panel→Surface, PanelLight→SurfaceHi, PanelDark→Well, Stroke→Edge, Primary→Gold,
Secondary→Violet, Good→Cash green, Bad→Danger).

### 2.2 Type

All faces ship with the client. Use `Font.new` so weights are explicit.

| Token | Font | Use |
|---|---|---|
| `Fonts.Display` | `Enum.Font.LuckiestGuy` | Hero only: window titles, reward card titles, "AURA SURGE", tutorial step title. Max three on screen. |
| `Fonts.UI` | `Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold)` | Buttons, tab labels, card titles, rail labels, pills (uppercase). |
| `Fonts.Body` | `Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium)` | Descriptions, tutorial copy, settings rows. Sentence case. |
| `Fonts.Number` | `Enum.Font.GothamBlack` | Every number: money, gems, counters, prices, timers, multipliers. Fixed-size, never `TextScaled`. |

Keep `Theme.Fonts.Title` and `Theme.Fonts.Body` as aliases (`Title = Display`, `Body = Body`) and add
`Theme.Fonts.UI`, `Theme.Fonts.Number`. `Kit.text` must accept `FontFace` as well as `Font`.

Type scale (`Kit.TEXT`, keep keys): Hero 40, H1 28, H2 22, H3 18, Body 16, Small 14, Tiny 12. Nothing
below 12 on desktop; Compact raises Tiny to 13 and hides most micro labels instead of shrinking them.

Text treatment: default `StrokeThickness = 0`. Shadow is a second `TextLabel` clone named `Shadow`
(same text, `TextColor3 = Ink`, `TextTransparency = 0.45`, offset `(0, 2)`, `ZIndex - 1`), produced by
`Kit.text` when `props.Shadow = true`; `Kit.title` sets `Shadow = true` by default and keeps a 1.5 px
`UIStroke` in `Kit.darken(surface, 0.4)` for Display text only.

### 2.3 Component recipes (Kit primitives, same function names and signatures)

Common techniques:

- **Shadow.** `Kit.shadow(parent, radius, strength)` (new helper, internal): a `Frame` named `Shadow`,
  `BackgroundColor3 = Ink`, `Size = (1, 12, 1, 14)`, `Position = (0, -6, 0, -2)`, `AnchorPoint 0,0`,
  `BackgroundTransparency = 0.6`, `UICorner radius + 6`, `ZIndex = parent.ZIndex - 1`, plus a second
  frame `Size (1, 24, 1, 28)`, `Position (0, -12, 0, -6)`, transparency 0.85, radius + 12. Two stacked
  soft rects read as a blurred shadow at UI sizes. If `rbxasset://textures/ui/GuiImagePlaceholder.png`
  style assets are tempted, do not: verify any `rbxasset://` path in Studio first; the frame version is
  guaranteed.
- **Rim light.** `Kit.stroke(parent, 1.5, Edge)` then a `UIGradient` child on the stroke:
  `Color = ColorSequence(Rim → Edge)`, `Transparency = NumberSequence{0: 0.35, 0.45: 0.85, 1: 0.95}`,
  `Rotation = 90`. One stroke gives a lit top edge and a dark bottom edge.
- **Glass body.** `UIGradient` vertical, Surface top → Surface bottom as in the table; `BackgroundTransparency 0.04`
  so the scene bleeds through slightly. Windows also add `BlurEffect` (see windows).

**`Kit.panel`** = Shadow + body (glass gradient, `UICorner` 16) + rim stroke. No white shine frame.
`props.Elevated = true` uses SurfaceHi. `props.StrokeColor` tints the rim (used by toasts/modals).

**`Kit.well`** = flat `Well` colour, `UICorner` 12, inner shade: a 1 px top `Frame` in Ink at 0.5
transparency (inset shadow), `BackgroundTransparency 0.1`.

**`Kit.button`** (keep props: Text, Icon, Layout, Color, Size, Depth, Radius, Font, TextSize, TextColor,
Sound, and keep `Kit.setButton`, `Kit.setEnabled`, `Kit.buttonFace`, `Kit.bouncy`):
- Layers: `Base` (`Kit.darken(color, 0.5)`, offset by `depth`, default depth 4, radius 12) → `Face`
  (gradient `lighten(color, 0.22)` top → `darken(color, 0.04)` bottom, radius 12, `ClipsDescendants`)
  → `Rim` stroke 1.5 px `darken(color, 0.55)` with the rim-light gradient → label.
- Remove `Shine`. Replace with `Sheen`: a `Frame` 44 px wide, full height, `BackgroundColor3 white`,
  `UIGradient` horizontal `Transparency {0:1, 0.5:0.7, 1:1}`, `Rotation = 18`, parked at `Position.X = -0.3`
  and swept to `1.3` over 0.9 s `Quad` every 4 s only when `props.Shimmer = true` (CTA buttons).
- Label: `Fonts.UI` 18 (16 under 44 px high), uppercase, `Text`, shadow label offset (0, 1.5) in
  `darken(color, 0.6)` at 0.4 transparency. `TextColor` defaults to Text; for Gold faces use Ink text
  `rgb(40, 28, 8)` (dark on gold reads premium; white on gold does not).
- States: hover `Face` gradient lighten +0.08 and `UIScale 1.03` over 0.1 s `Quad`; press: `Face`
  `Position.Y = depth`, `Base` hidden, scale 0.97 over 0.06 s `Quad In`; release: back to rest over 0.16 s
  `Back Out`; disabled: `PadDisabled` fill, label 0.35 transparency, no sheen.
- `Layout = "Stack"`: icon is a `Kit.icon` shape (see 2.4) 46 % of face height, label `Fonts.UI` 12.
- `Icon` string that is an emoji is still accepted (popups), but Hud/Windows pass icon names.

**`Kit.pill`** = flat tinted chip, height 22, `UICorner` full, background `color` at 0.78 transparency,
1 px stroke `color` at 0.4 transparency, text `lighten(color, 0.45)` in `Fonts.UI` 12 uppercase, no text
stroke, `Rotation` ignored (set to 0). Solid variant (`props.Solid = true`) for badges: fill `color`,
text Ink/white by luminance. `Kit.setBadge` uses the solid variant in Danger.

**`Kit.progress`** = track `Well` radius full, 1 px inner shadow line; fill gradient `color` →
`lighten(color, 0.25)` horizontal with a 2 px lighter top line; value label `Fonts.Number` 14 with shadow.
Value tween 0.35 s `Quint`.

**`Kit.switch`** = 52x28 track (`Well` off / `Cash green` on), 22 px knob white with shadow, 0.14 s `Quad`.

**`Kit.window`** (same signature, same return table):
- Dim: `Kit.backdrop` in Ink at 0.45, fade 0.2 s; plus a `BlurEffect` in `Lighting` named `UiBlur`
  tweened `Size 0 → 10` while any window is open (`Windows.open`/`closeAll` manage the count; cheap on
  mobile at size 10).
- Frame: `Kit.panel` Surface, radius 18, 4 px shadow, rim stroke tinted 30 % toward `color`.
- Header: not inset. A 56 px band across the top of the frame, gradient horizontal `darken(color, 0.12)`
  → `color`, with the lower corners squared by a 20 px cover `Frame` in the same gradient. Left: 36 px
  rounded-square icon chip (`SurfaceHi` at 0.2 transparency, `Kit.icon`). Title `Fonts.Display` 26
  uppercase, Ink text when `color` is Gold, white otherwise, shadow on. No tilted medallion.
- Close: 40x40, radius 12, flat Danger with rim, glyph built from two 3 px white `Frame`s rotated ±45°
  (crisp at any scale), hover scale 1.06, press 0.94.
- Content: `Kit.well` inset 12 px below the header, `Size (1, -24, 1, -80)`, `Position (12, 68)`.
- Open: `UIScale 0.94 → 1` and `GroupTransparency 1 → 0` (wrap `frame` contents in a `CanvasGroup`
  only if performance allows; otherwise tween `BackgroundTransparency` of body and a `UIScale`),
  0.22 s `Quint Out`. Close: scale 1 → 0.96 and fade over 0.14 s `Quad In`. `Back` is not used here.

**`Kit.tabs`** (new, used by Shop and Index filters): a `Well` segmented control, height 40, radius 20;
tabs are text-only `Fonts.UI` 15 in TextDim; the selected tab is a `Frame` "Indicator" in the window
accent (radius 16, rim) that tweens `Position` to the selected tab in 0.18 s `Quint`; selected text turns
Ink or white by luminance.

**Cards** (Windows helper `card()`): `SurfaceHi` glass, radius 14, rim stroke, 2 px shadow. A 4 px accent
bar on the left edge (rarity or pass colour) or an icon medallion top-left; title `Fonts.UI` 16;
description `Fonts.Body` 14 TextDim; price as a full-width green button 40 px at the bottom. Tags
("POPULAR", "BEST VALUE") are solid pills in the top-right corner, 0°, overlapping the edge by 6 px.

**`Popups.toast`** (same signature): 440x44 glass capsule (`Surface` at 0.08 transparency, radius 22,
rim tinted by tone), 4 px tone bar on the left inside the radius, 28 px icon chip, text `Fonts.UI` 15
with shadow. Enter: slide from `Position.Y - 16` with fade, 0.22 s `Quint Out`; exit: fade + slide up
0.3 s `Quad In`. Max four stacked, 6 px gap.

**Modals / reward cards / crate reveal** (keep all `Popups.*` signatures): same panel recipe, Ink
backdrop at 0.55 plus blur 14; keep `Popups.rays` and `medallion` (these are the moments that deserve
`Back` easing, confetti and tilt). Medallion keeps its gradient disc but gets the rim stroke and a shadow
instead of a 4 px black stroke. Buttons inside modals: primary gold with shimmer, secondary `SurfaceHi`.

**Tutorial card**: `Surface` glass with a 4 px Gold bar on the left, step pips as 8 px dots (current one a
24x8 gold capsule), title `Fonts.Display` 20, body `Fonts.Body` 15 TextDim, "Skip" as a text-only ghost
button (TextDim, underline on hover). Advance pulse stays (scale 1.06 → 1 `Back`, rim flashes Cash green).

### 2.4 Icons (`Kit.icon(parent, name, size, color)`, new)

Returns a transparent `Frame` of `size` holding shapes. Each shape is `Frame`s with `UICorner`,
`UIGradient` (lighten 0.3 top → color bottom) and a 1 px rim; a single `Shadow` frame under the group.
Text glyphs come from `Fonts.UI` (Builder Sans) which has crisp ★ ✓ ✕ ▲ ● ♥ glyphs; they are text, not
emoji, so they inherit colour and shadow.

| Name | Build |
|---|---|
| `Coin` | circle disc Gold gradient, inner ring (round `Frame`, stroke only 2 px `deep gold`, 72 % size), "$" `Fonts.Number` 55 % in `rgb(120, 76, 8)`. |
| `Gem` | square rotated 45° Rizz blue gradient, radius 3; second square 55 % size rotated 45° `lighten 0.5` at 0.35 transparency offset up-left (facet). |
| `Shop` | rounded rect bag (radius 5, 70 % wide, 60 % tall, bottom aligned) in Gold; handle: round frame 40 % size, `BackgroundTransparency 1`, stroke 3 px Gold, clipped to the top half by a `ClipsDescendants` frame. |
| `Index` | two rounded rects 60x72 %, the back one Violet deep offset (-4, -4), the front Violet with a 2 px vertical line at 30 % (spine). |
| `Ranking` | cup: rounded rect 48x52 % Gold with radius bottom 14 (use a second frame for the rounded bottom), two stroke-only rings 26 % size at left/right midline (handles), stem 10x10 %, base rect 50x8 %. |
| `Home` | square 56x44 % bottom aligned `SurfaceHi lighten`, roof: square 56 % rotated 45° positioned above, clipped to its top half; door: 16x24 % Gold. |
| `Free` | gift: rect 64x46 % Cash green bottom, lid 72x16 % lighter, ribbon: vertical 12 % bar Gold full height, horizontal 12 % bar across the lid. |
| `Invite` | two heads (round, 28 %) at (30 %, 32 %) and (62 %, 32 %), two bodies (rounded rect 44x30 %, radius full on top via UICorner 50 %) in Violet and Rizz blue, the front one overlapping. |
| `Settings` | reuse the existing frame-built gear in `Hud.luau` (`GearIcon`), moved into `Kit.icon`. |
| `Surge` | `⚡` is acceptable as a text glyph in `Fonts.UI` tinted Surge amber; if it falls back to emoji, build: two 3-sided shapes from rotated rectangles clipped by `ClipsDescendants` parents. |
| `Star`, `Check`, `Close`, `Plus` | text glyphs ★ ✓ ✕ + in `Fonts.UI`, or two rotated 3 px frames for ✕ and +. |
| `Chad` (unit counter) | small `ViewportFrame` head of the Tier 1 model via `Kit.unitViewport` (already exists) at 28 px; fallback: Rizz blue circle with Ink "C". |

`Theme.Icons` keeps the emoji strings for copy in popups; add `Theme.IconNames` mapping the same keys to
`Kit.icon` names so Hud/Windows can switch without touching callers.

### 2.5 HUD layout (1280x720 design space, scaled by `rescale`)

Target: four quiet blocks plus one CTA.

**Top-left: Wallet** (`Wallet`, keep child names `Coin`, `Money`, `CashMult`, `Gems`, `Amount`, `Add`;
keep `Hud.shakeWallet`, `Hud.walletIdle`, `Hud.coinBurst` and the `Hud.anchors` / `Hud.predictCarried`
members if the concurrent edit adds them).
- 252x84 glass panel at (14, 10). Row 1: `Coin` icon 34 px, money `Fonts.Number` 30 in money green with
  shadow (count-up tween, punch scale 1.08 → 1 over 0.25 s `Back`). Row 2: `x1.0 CASH` pill (Gold tint)
  and, in the same row, `Gem` 18 px + amount `Fonts.Number` 16 + a 24 px `+` button in Rizz blue.
- The `Chips` row (friends/premium/surge) is removed as a separate row. Merge into a single pill
  `BONUS +10%` on row 2, right-aligned; tapping it toggles a 2-second tooltip listing the sources
  (`Fonts.Body` 13 in a small glass card). Keep the `friendsChip`/`premiumChip`/`surgeChip` variables as
  labels inside that tooltip so the refresh code stays as-is.

**Left rail: Menu** (`Menu`, keep `Hud.buttons[name]` keys `Shop`, `Index`, `Ranking`, `Free`, `Home`,
`Invite`).
- One vertical `UIListLayout` at (14, 104), gap 8, buttons 60x60 (touch 68), radius 14, all `SurfaceHi`
  glass with the rim light; only the icon carries colour (Shop gold, Index violet, Ranking gold cup,
  Free green, Invite blue, Home neutral). Label `Fonts.UI` 11 TextDim under the icon. Badges: solid
  Danger pill 18 px top-right, 1 px rim.
- Order: Shop, Index, Ranking, Free, Invite; Home moves to the top-right cluster next to the gear (it is
  used rarely). Five buttons = 332 px tall, ending at y = 436.

**Promo** (`Promo`, `Buy`, `Tag`, `Price`): the one shimmering CTA. 136x48 gold button at (14, 448) under
the rail: coin icon, "2x CASH" `Fonts.UI` 16 Ink text, `Shimmer = true`; the price is a Solid pill
`199 R$` overlapping the bottom-right corner at 0°; "PERMANENT" becomes the pill text on the left edge,
also at 0°. Hidden in Compact or when owned (existing `applyCompact` logic).

**Top centre: Aura bar** (merge `Counter` and `Gauge` into one capsule; keep the `counterLabel`,
`multLabel`/`Value`, `Bar`, `Even`, `Marker`, `Nice` names inside).
- 360x56 glass capsule at (0.5, 0) anchored top, y = 10. Left third: `Chad` icon + `Fonts.Number` 20 count
  + "CHADS" `Fonts.UI` 11 TextDim. Right two-thirds: `AURA x0.5` label `Fonts.Number` 16 (Gold when ≥1,
  TextDim below) above a 10 px progress capsule with the "even" marker as a 2 px white tick; "changes in
  18s" becomes a right-aligned `Fonts.Number` 12 TextMute countdown.
- Surge banner (`SurgeBanner`, `SurgeBar`) keeps its slot below this capsule, restyled as a Surge amber
  capsule with `Fonts.Display` 18 and a shimmer.

**Top-right cluster** (`Surge` timer, `Settings`, `Home`): three 40 px glass squares in a horizontal list
at (1, -14) anchored top-right, y = 10; the surge timer is a 120x40 capsule with the `Surge` icon and
`Fonts.Number` 18 countdown. Gear uses `Kit.icon("Settings")`.

**Bottom centre: Tank** (`Tank`, `Carried`, `Fill`; keep `Hud.pulseTank`).
- 320x54 capsule at (0.5, 1) anchored bottom, y = -24. The capsule itself is the progress track: fill
  gradient Violet → `Orb`, moving left to right; a 2 px lighter top line on the fill; inside, left:
  `Orb`-coloured dot + "AURA" `Fonts.UI` 13; centre: carried amount `Fonts.Number` 22; right: state text
  (`WALK OVER AURA` / `DEPOSIT!`) `Fonts.UI` 12 TextDim, turning Gold with a slow pulse (0.8 s `Sine`
  loop, transparency 0 → 0.35) when full. Drop the separate `Shine` frame.
- Tutorial card sits 12 px above the tank, 440x84, left accent bar Gold (see 2.3).

**Version label**: `Fonts.Body` 11 TextMute at bottom-left, 0.4 transparency.

**Compact (phones, `screen:GetAttribute("Compact")`)**: rail buttons 48 px icon-only (labels hidden),
wallet 200x60 single row (gems move into the `+` button tooltip), aura bar 280x44, tank 260x44, tutorial
card 340x72, promo and bonus tooltip hidden, surge timer 96x34. Touch targets never below 44 px.
`rescale` in `Main.client.luau` stays as is; consider raising the Compact threshold from 600 to 640 so
tall 18:9 phones also get the compact rail.

### 2.6 Window content

- **Shop**: `Kit.tabs` (Passes / Cash / Rizz) under the header. Passes: three dark cards 240x210 with a
  48 px icon medallion in the pass colour, title `Fonts.UI` 16, description `Fonts.Body` 13 TextDim, price
  button green 40 px; owned state swaps the button for a Cash green outline pill "OWNED ✓". Cash/Rizz: a
  2x3 grid of 236x72 row cards: left icon medallion (coin stack / gem), amount `Fonts.Number` 22 green or
  blue, sub-label `Fonts.Body` 12 TextMute, price button 88x36 green right-aligned. Tags as solid pills.
- **Index**: keep the layout; filter chips become `Kit.tabs`-style segmented control with rarity dots
  (8 px discs) instead of six coloured pills; cards get the rarity as the left 4 px bar and name in
  `Fonts.UI` 14; undiscovered cards use the silhouette at 0.25 transparency on `Well` with "???" in
  `Fonts.Number` 16 TextMute; "NEW" solid Cash green pill at 0°.
- **Ranking**: table rows 40 px alternating `Well`/`Surface`, rank `Fonts.Number` 16 (top three in Gold,
  silver `rgb(200, 204, 220)`, bronze `rgb(205, 127, 50)`), name `Fonts.UI` 15, value `Fonts.Number` 16
  green right-aligned; the local player's row rim-lit in Gold.
- **Settings**: rows 52 px with label `Fonts.UI` 15 left and `Kit.switch` right; section titles
  `Fonts.UI` 12 TextMute uppercase.

### 2.7 Motion language

| Event | Duration | Easing | Notes |
|---|---|---|---|
| Window open | 0.22 s | Quint Out | scale 0.94→1 + fade; backdrop 0.2 s; blur 0→10 |
| Window close | 0.14 s | Quad In | scale 1→0.96 + fade |
| Tab switch | 0.18 s | Quint Out | indicator slides; page cross-fade 0.12 s |
| Button hover | 0.10 s | Quad Out | scale 1.03, face +0.08 lighter |
| Button press | 0.06 s | Quad In | scale 0.97, face drops by depth |
| Button release | 0.16 s | Back Out | overshoot 1.0 |
| CTA shimmer | 0.9 s sweep every 4 s | Quad InOut | only `Shimmer = true` buttons |
| Money change | 0.4 s count-up | Quint Out | label punch 1.08→1, 0.25 s Back Out |
| Progress fill | 0.35 s | Quint Out | |
| Toast in / out | 0.22 s / 0.30 s | Quint Out / Quad In | slide 16 px + fade |
| Reward / crate / purchase | existing | Back Out, rays, confetti | these keep the bounce; everything else gives it up |
| Tank full pulse | 0.8 s loop | Sine InOut | text/rim transparency 0→0.35 |
| Badge appear | 0.2 s | Back Out | scale 0→1 |

---

## 3. Implementation plan (prioritised, by file)

Each step must keep every existing export: `Kit.*` function names and signatures, `Kit.TEXT`,
`Kit.RADIUS`, `Kit.C`, `Hud.buttons`, `Hud.pulseTank`, `Hud.coinBurst`, `Hud.shakeWallet`,
`Hud.walletIdle`, `Hud.freeClaimedAt`, `Hud.anchors` and `Hud.predictCarried` (if present after the
concurrent edit), `Popups.*`, `Tutorial.*`, `Windows.open/closeAll/build`, and the `Compact` attribute
protocol in `Main.client.luau`. Run `scripts/check.sh` after each step.

1. **`src/themes/chad/Theme.luau`** (foundation, small): add the palette tokens from 2.1 (keeping the old
   keys as aliases), `Theme.Fonts.Display/UI/Body/Number` via `Font.new`, keep `Title`/`Body`/`Mono`
   aliases, add `Theme.IconNames`. No visual change yet.
2. **`src/client/UI/Kit.luau`** (biggest impact, one PR):
   a. `Kit.text`: support `FontFace`, default `StrokeThickness = 0`, add `Shadow` option; `Kit.title`
      defaults to Display + shadow + 1.5 px tinted stroke.
   b. Add `Kit.shadow`, rim-light `Kit.stroke` (gradient child when `color == Edge`), `Kit.icon`,
      `Kit.tabs`, `Kit.shimmer(face)`.
   c. Rebuild `Kit.panel`, `Kit.well`, `Kit.pill`, `Kit.button` (states, sheen, Ink text on gold),
      `Kit.progress`, `Kit.switch`, `Kit.window` (backdrop + blur + flat header + crisp close),
      `Kit.setBadge` (solid pill).
   This alone removes the outlines, the gloss strips, the black borders and the sticker tilt everywhere.
3. **`src/client/UI/Hud.luau`**: merge Counter+Gauge into the aura capsule; rail to a vertical list of
   `SurfaceHi` buttons with `Kit.icon`; wallet to two rows with the bonus pill; promo to the CTA button;
   tank to the capsule track; top-right cluster; Compact variants. Keep every `Name` listed in 2.5 so
   `Popups.float` anchors and tests keep working.
4. **`src/client/UI/Windows.luau`**: `Kit.tabs` in Shop and Index; `card()` helper; pass/cash/rizz cards;
   ranking rows; settings rows; drop `ribbon()` rotation (solid pill at 0°).
5. **`src/client/UI/Popups.luau`**: toast capsule and slide; modal backdrop + blur; medallion rim; button
   roles (gold primary with shimmer, `SurfaceHi` secondary); keep rays/confetti.
6. **`src/client/UI/Tutorial.luau`**: glass card with left bar, pips, ghost Skip, Body font for copy.
7. **`src/client/Main.client.luau`**: optionally raise the Compact threshold to 640; nothing else.
8. **Verification**: re-capture the five views plus Ranking, a reward card, a toast and a phone layout
   (Studio device emulator, iPhone 14) into one contact sheet; art-director pass with the checklist:
   max two loud elements on the HUD, no black text outlines outside hero labels, no emoji on HUD or
   window chrome, every number in `Fonts.Number`, windows dim the scene.
