# Skinning an addon for EllesmereUI — findings and lessons

Written while adding EllesmereUI support to Postbox (July 2026, WoW 12.0.7 → 12.1),
updated on 2026-07-31 against the shipped skinning API in **EllesmereUI v8.6.8**,
and again on 2026-09-27 against **EllesmereUI v9.2.9** (the looks of §1.3, the
live signals of §1.4, the border survey of §4). Most of this was learned the hard
way and is **not** in EllesmereUI's own developer guide. It should transfer
directly to the MountsJournal EllesmereUI skin and any other addon in the suite's
style.

---

## 1. The API situation (read this first)

EllesmereUI has a first-class third-party skinning API —
`EllesmereUI.RegisterSkin(name, fn)`, documented in `SKINNING_API.md` at its repo
root. It shipped in a tagged release on **2026-07-31, v8.6.8**, having lived on
`master` since 2026-07-29.

> **Lesson kept because it cost real time:** verifying that an API exists in a
> project's *source* is not the same as verifying it exists in a *release the
> user can install*. Postbox's first implementation guarded on
> `if not EllesmereUI.RegisterSkin then return end`, which meant it silently did
> nothing for every real user for as long as the API was master-only. Always
> check `git ls-remote --tags`, and check the version in the user's actual
> AddOns folder.

### The shipped contract, in one place

- **`S.apiVersion` is `1`**, and the surface is **additive-only**: existing
  functions and their signatures will not change. So read the version as a
  *floor*, never a match, and treat an absent or non-numeric field as 1 rather
  than as grounds to bail — the alternative costs the user the real skin over a
  missing annotation.
- Register with your **folder name**. First registration of a name wins, and the
  name is also the key the per-addon toggle is stored under, so anything else is
  both collision-prone and unswitchable. Postbox registers `"Postbox"`, taken
  from the file's own `...` vararg rather than typed as a literal.
- `RegisterSkin` in the **parent** addon is only a stub that queues. The
  dispatcher lives in the **`EllesmereUIBlizzardSkin` sub-addon**. This split is
  the whole reason §1.1 below exists.
- Callbacks fire **once per session at `PLAYER_LOGIN`**, or immediately for
  registrations arriving after that, and each is `pcall`-isolated.
- Gating is two account-global saved variables, both **nil = on**:
  `EllesmereUIDB.thirdPartySkinsOff` (master) and
  `EllesmereUIDB.thirdPartySkinAddons[name] == false` (per addon). Switching
  skinning **off** is reload-bound; switching it **on** dispatches live.
- The facade: `S.Shell(frame [, opts])` (curried per addon; `opts.noBorder`,
  `opts.noTopBar`, `opts.bottomBar`), `S.IsEnabled()`, the pass-throughs
  `Panel, Inset, FadeRegions, FadeNineSlice, Button, WhiteButtonLabel,
  StateButtonLabel, EditBox, Checkbox, Dropdown, ScrollBar, Tab, CloseButton,
  PageButton, SquareIcon, SortHeaderBar, Font, White, ApplyBarFill`, and the
  getters `GetStyle() -> "eui"|"modern"`, `GetAccentColor() -> r,g,b`,
  `GetPanelColor() -> r,g,b,a`, `GetFont() -> path, flag`, `OnLooksChanged(fn)`.
- **`OnLooksChanged` fires less often than its comment says.** It rides
  EllesmereUI's accent registry (`WSkin.RefreshLooks`, a `RegAccent` callback),
  so it fires on accent changes — once per tick while a colour picker is
  dragged — and on Blizz UI Enhanced's global look settings. It does **not**
  fire on a window-style switch (that path calls only `RefreshStyles`) or on a
  profile switch. See §1.4 for what does.
- **This whole API needs Blizz UI Enhanced** (`EllesmereUIBlizzardSkin`). Players
  who run EllesmereUI with that module disabled — Postbox's own maintainer among
  them — never get a facade at all, so the compat backend below is not a legacy
  path: it is the everyday path for a real share of players.
- **The pass-throughs are late-bound.** Each looks its primitive up in the
  engine at call time and returns quietly if it is not there. A call that did
  nothing therefore still comes back from `pcall` as a success — see §6 for the
  one place in Postbox where that mattered.

### The two-backend pattern

Postbox ships two backends behind one skinning body, selected at `PLAYER_LOGIN`:

| Backend | When | What it does |
|---|---|---|
| `api` | a facade actually arrives (8.6.8+) | Uses the official facade. EllesmereUI owns every visual. |
| `compat` | Blizz UI Enhanced (`EllesmereUIBlizzardSkin`) disabled or absent, any version; 8.6.7 and earlier; or the dispatcher silent | Rebuilds the same facade from the public helpers 8.6.6 *does* export. |

The switch is automatic: updating EllesmereUI, or enabling Blizz UI Enhanced,
brings the `api` backend at the next login. `/postbox skin` prints which is live.

> **Do not retire `compat` as a legacy path.** It was removed once on exactly
> that reading (the old-version row alone) and restored the same day: with Blizz
> UI Enhanced off, the window fell to a stand-in with a different accent, fonts
> and opacity, and a player's everyday EllesmereUI setup no longer matched.

**Defer registration to `PLAYER_LOGIN`.** Do not decide at file-load time —
`OptionalDeps` affects load order but a load-time guard bakes in a permanent
no-op if anything is off. At `PLAYER_LOGIN` EllesmereUI is fully initialised
either way, and the API's own dispatcher explicitly supports late registration.

### 1.1 Silence is not one condition — it is three

Register, and your callback may simply never arrive. Answering that with "fall
back to the shim" is wrong in one of the three cases, and it is the case where
being wrong matters most. Postbox asks two read-only, nil-guarded questions --
at once, at login, when the dispatcher is not loaded (nothing could ever
answer), and after a 5 s wait only when it is loaded and has not answered yet:

| Cause | Detect | Answer |
|---|---|---|
| **Sub-addon absent or disabled.** The parent stub queued us and nothing will ever drain the queue. | `C_AddOns.IsAddOnLoaded("EllesmereUIBlizzardSkin")` is false (legacy global `IsAddOnLoaded` as fallback) | **Compat shim** — this is exactly the pre-8.6.8 situation. |
| **User opted out.** They switched Postbox (or the master) off in EUI's third-party options. | `EllesmereUIDB.thirdPartySkinsOff`, or `EllesmereUIDB.thirdPartySkinAddons["Postbox"] == false` | **Stand down entirely** — no shim, no skin. |
| **Genuine breakage.** Dispatcher loaded, toggles on, still silent. | neither of the above | **Compat shim**, as before. |

The opt-out case is the point of the exercise. Answering "don't skin Postbox
like EllesmereUI" with a hand-built imitation of EllesmereUI is not a fallback,
it is ignoring the setting. Postbox therefore leaves `ns.Skin` unclaimed, renders
its own theme, and records `standDown = "hostoptout"` in the same diagnostics
`/postbox skin` reports.

**Do not wait for a callback that cannot come.** Postbox used to wait the 5 s
in every case, so with Blizz UI Enhanced off -- the everyday compat path -- a
window, a font string or the minimap icon made in those seconds was made
before any skin had claimed: in Postbox's own theme, in the game font, in
Postbox's accent, and it kept that look for the session. With the dispatcher
absent the answer is known at login, so that is when it is given. A claim that
still lands late (the watchdog's, or skinning switched back on mid-session)
skins every Postbox window already built, repaints the accent icons and moves
text set before the face existed into it.

**Do not poll to recover from the opt-out.** The registration stays in
EllesmereUI's queue, and switching skinning back on dispatches live — so the
callback itself is the re-entry path, and a timer would only race it.

**Make the late callback idempotent, not a repaint.** A callback arriving after
the shim is already up is a real path, not a theoretical one (that is precisely
the opt-in-mid-session case). It must win *from that point on* without drawing
anything twice, because a WoW texture can be faded and never destroyed — so
there is no way to un-shim a window that is already painted. In Postbox the
swap is: replace `S`, set the backend to `api`, re-run activation. Every
already-skinned frame bails on its own idempotency key
(`__pbEuiSkinned`, `__pbShimShell`, `__pbShimTab`), so nothing double-paints,
and every frame built afterwards is house art. The swap's one immediate effect
is that activation now registers the live-looks callback with the **real**
`S.OnLooksChanged` instead of the shim's documented no-op.

One interaction worth knowing: with ElvUI also loaded, Postbox's ElvUI skin
re-checks `ns.Skin` a second after this watchdog and takes an unclaimed window.
That is deliberate — the user opted out of EllesmereUI's skinning, not of the
ElvUI they are also running.

### Known gaps on the `api` backend

- `S.Shell()` draws EllesmereUI's own shell, whose textures are not reachable
  *through the facade*. They are, however, regions of a frame you own, so the
  diff before/after the call is the handle. Postbox does exactly that
  (`ApplyShell` / `CaptureHostArt`) to drive §3's transparency. If the diff comes
  up empty — a host that draws no reachable art at all — Postbox's own flat fill
  carries the backdrop instead, and that path is compat-shim-shaped even on the
  `api` backend.
- `S.OnLooksChanged` does not fire on a **profile switch**, which moves
  `GetDarkModeFill()` — Postbox's entire baseline colour *and* its alpha — nor
  on a window-style switch. The profile switch is now covered live by
  `RegisterDarkModeRefresh` (§1.4). The window-style switch has no signal at all;
  Postbox keeps an `OnShow` hook on each skinned window, so close-and-reopen
  picks it up.

### 1.2 Live restyles: what the engine does, and what you still have to do

Registered shells live-restyle through the engine's own refresh path — you do
not re-call `S.Shell`. Two cases, and Postbox's region/child **count** heuristic
(`RescanHostArt`) is sound for both:

- **Replacing art** (the `eui` and `modern` backdrops are different textures) can
  only ever *add* regions, since WoW textures are never destroyed. The count
  moves, the re-diff runs, the new textures are adopted.
- **Reusing art in place** leaves the counts alone, which is equally fine: your
  alpha is already on those same texture objects. If the repaint reset it, your
  `OnLooksChanged` handler re-applying opacity is what puts it back.

What is **not** provable from the published API is the *ordering* — whether the
restyle completes before the `OnLooksChanged` callbacks fire. Postbox sidesteps
it: every live signal is folded into one pass on the **next frame** (§1.4), after
anything the host queued in this one.

**The restyle does retire art by alpha — so the opacity pass must not undo it.**
Reading the 9.2.9 engine settled what used to be a watch item. `S.Shell` lays
down *both* backdrops at once — the `modern_blizz.png` atlas at `BACKGROUND -8`,
a black 0.62 overlay at `-7`, a flat Modern fill at `-6`, the title strip at `-5`
— and `ApplyShellStyle` picks one purely by region alpha: under Modern it holds
the atlas and overlay at **0**, and on every `RefreshStyles` it sets them back to
0 or 1. An opacity pass that raised every host region to the player's alpha put
the EllesmereUI atlas back under the Modern fill. Postbox now drives a host region
only while the host shows it: it remembers the alpha it wrote last, and a region
whose alpha no longer matches was set by the host since, so its shown/hidden
state is re-read from that value (the host only ever writes 0 or 1). Under the
EllesmereUI style every region is shown and the pass is the single `SetAlpha` it
always was. The one blind spot is a restyle while the window sits at exactly 0%
opacity (zero over zero), which the next restyle or `/reload` settles.

`RefreshStyles` also resets the shown regions to alpha **1** — full opacity —
and tells no one; the `OnShow` re-assert is what brings the player's alpha back.

### 1.3 EllesmereUI's looks (9.2.5+) and what a third-party window should do

EllesmereUI 9.2.5 added a look switch under **Global Settings › Style**: its own
look, **Blizzard Style** (the current stock art) and **Classic WoW UI** (the
vanilla art). What there is to read, and what there is not:

- **The flags are per module and reload-gated.** Each module (unit frames,
  action bars, minimap, damage meters, chat, …) has `useBlizzardStyle` /
  `useClassicStyle` in its own profile, written only inside the reload prompt's
  confirm, and latches its rendering style once per session
  (`EllesmereUI._ModuleNS[folder].<Module>Style()`, e.g.
  `_ModuleNS.EllesmereUIMinimap.MinimapStyle()`).
- **There is no single whole-UI setting, but there is a record of the whole-UI
  switch** (the first-install picker and the Style page's *Apply to All*), per
  profile: `profiles[p].windowSkinLook` (written beside the window-skin swap, Blizz
  UI Enhanced only) and the parent's font record `fonts._styleSlots.active`
  (present without Blizz UI Enhanced; absent in glyph-fallback locales).
  `EllesmereUI.ProfileWindowSkinLook(prof, liveFonts)` reads exactly that pair
  when Blizz UI Enhanced is loaded. Under a stock look Blizz UI Enhanced turns its
  skins **off** Blizzard's windows (first visit: every window at *Blizz Default*).
- **The skinning API ignores all of it.** `S.GetStyle()` still answers only
  `eui`/`modern`, and `GetThirdPartySkinStyle` deliberately keeps voting from the
  EllesmereUI look's window slot, so a third-party skin stays on the EllesmereUI
  theme under a stock look. There is no change signal either: a look change is a
  reload in EllesmereUI itself.

What Postbox does with that: its style option's first entry ("EllesmereUI") now
means *follow EllesmereUI's look*. Under the EllesmereUI look it is the skin
described in this document, unchanged. Under Blizzard Style or Classic WoW UI —
read once at activation, like the modules' own latches — the skin stands down
and Postbox wears its own Blizzard-art look, which is what sits right next to
the stock Blizzard windows EllesmereUI now leaves alone. The options panel says
so ("Following EllesmereUI's look"), and a player who wants something else picks
another style. Every read is nil-guarded, and anything unreadable is the
EllesmereUI look — what every session was before 9.2.5.

**Dark Mode** is a per-module switch between class-coloured and dark bars; the
*palette* behind it (`GetDarkModeFill`) is what Postbox follows, whether or not
any module has Dark Mode on — the window has no class colour to fall back to.

### 1.4 Live signals: what fires, and when

| Signal | Where | Fires on | Backend |
|---|---|---|---|
| `S.OnLooksChanged(fn)` | skin facade | accent (per picker tick), Blizz UI Enhanced global look settings | api only |
| `EllesmereUI.RegisterDarkModeRefresh(fn)` | parent addon | Dark Mode palette edits, darken sliders, the Dark Mode master switch, **every profile switch** (the repoint calls `RefreshDarkMode`) | both |
| `EllesmereUI.RegAccent({ type = "callback", fn = fn })` | parent addon | accent (per picker tick); calls entries **without** a pcall | both (Postbox uses it on compat only) |
| *(nothing)* | Blizz UI Enhanced | window-style switch (`RefreshStyles`), Modern colour edits | — |

Postbox routes all three into one request that runs on the next frame. Two
reasons beyond de-duplicating a picker drag: a profile switch refreshes the dark
palette *before* it re-resolves the accent (`RefreshAllAddons` calls
`RefreshAccent` after the repoint), so a pass inside the first callback would
paint the old accent; and the next frame is after every host repaint queued in
this one. A `RegAccent` entry must never throw — it runs in the middle of
EllesmereUI's own accent pass — so Postbox's is a `pcall` around a flag.

---

## 2. Where the "EllesmereUI look" actually comes from

This was the hardest thing to find. There are **three separate systems**, and
picking the wrong one produces a window that is subtly but persistently off.

### `EllesmereUI.GetDarkModeFill()` — the real baseline ⭐

```lua
local r, g, b, a = EllesmereUI.GetDarkModeFill()   -- colour AND alpha
local r, g, b, a = EllesmereUI.GetDarkModeBg()     -- the lighter bg/border tone
```

Resolves the **active profile's** `darkMode` table, falling back to
`EllesmereUI.DEFAULT_DARK_MODE`. This is the value shared across unit frames,
bars and panels, and it is what a profile import actually sets:

| Profile | fill | alpha |
|---|---|---|
| `DEFAULT_DARK_MODE` (plain EllesmereUI) | `#111111` | `0.90` |
| atrocityUI / AES import | `#080808` | `0.80` |

**Use this as your baseline colour *and* transparency.** It is per-profile and
live, so reading the accessor (never hardcoding, never caching) means the addon
follows profile switches — once something makes it read again.
`EllesmereUI.RegisterDarkModeRefresh(fn)` is that something: EllesmereUI runs its
refreshers on every palette edit and every profile switch (§1.4). atrocityUI is
not doing anything magic — it is just an EllesmereUI profile that sets these
keys.

### `EllesmereUI.RESKIN` — tooltips, context menus, popups only

```lua
EllesmereUI.RESKIN = {
    BG_R = 0.067, BG_G = 0.067, BG_B = 0.067,
    TT_ALPHA = 0.92, CTX_ALPHA = 0.95, QT_ALPHA = 0.97, BRD_ALPHA = 0.18,
}
```

Do **not** use this for window backdrops. It is the palette for Blizzard tooltip
and menu reskins.

### The window-skin engine — least useful for third parties

`EllesmereUIBlizzardSkin`'s shell has two styles, `eui` (atlas art) and `modern`
(flat user colour). See §3 for why the atlas is a trap.

---

## 3. Transparency: the `modern_blizz.png` trap

EllesmereUI's `eui` window style draws
`Interface\AddOns\EllesmereUI\media\modern_blizz.png` + a black `0.62` overlay.
Reproducing that faithfully gives a window that **cannot be made transparent**:

```
modern_blizz.png = 1122x866, colorType 3 (palette), chunks: IHDR PLTE IDAT IEND
                 = no tRNS chunk = every pixel 100% opaque
```

Two consequences that cost several rounds to find:

1. **A solid plate placed *under* the art is invisible.** An early attempt drove
   an "opacity" setting through such a plate; it did literally nothing, because it
   sat behind an opaque texture.
2. **The art is cover-fit cropped to each window's aspect ratio.** A 540×440
   window shows a different, lighter region of the image than a wide one, so two
   windows using the identical recipe still do not match.

> **Lesson:** when a visual setting "does nothing", check whether the thing you
> are changing is even reachable by light. Decode the asset — `colorType` and the
> presence of a `tRNS` chunk in a PNG header is a 10-line script and settles it.

**What works:** draw a flat fill in the `GetDarkModeFill()` colour and drive
*that texture's* alpha. It is transparent at any value, matches the rest of the
user's UI, and has no crop problem.

**Trade-off to be aware of:** a plain-EllesmereUI user's Blizzard windows keep the
textured atlas shell, so a flat-fill addon window matches their unit frames rather
than their Blizzard windows. Consider offering both as an option.

### "Match EllesmereUI": which windows it matches

Postbox's opacity setting defaults to matching the windows beside it, and which
windows those are depends on the backend (`HostWindowAlpha` in
`Core/Skin_EllesmereUI.lua`). Postbox's own fill is in the Dark Mode fill's
colour (§2) on both.

- **api** (Blizz UI Enhanced on): EllesmereUI draws Blizzard's windows, so
  Postbox matches them — opaque under the EllesmereUI window style, the Modern
  backdrop's own opacity (97% by default) under Modern. The Dark Mode fill's
  alpha is for unit and raid frames (90% by default); following it here made
  Postbox a touch more see-through than every window beside it.
- **compat** (Blizz UI Enhanced off): EllesmereUI draws no Blizzard window at
  all, so there is none to match, and "opaque" left Postbox a solid slab beside
  the see-through windows another skinner paints. It follows the **Dark Mode
  fill's alpha** instead — 80% in an atrocityUI profile, the same grey at the
  same 80% atrocityEssentials paints Blizzard's windows in (since 2026-09-30).

Also note: **opacity ≠ darkness.** An additive black wash makes a window darker
while leaving it just as see-through. Only the backdrop texture's own alpha
produces transparency.

---

## 4. The shared border engine (available in 8.6.6, no API needed)

This is the Glow / Shadow / texture picker used throughout the suite.

```lua
EllesmereUI.GetBorderTextureList()                  -- built-ins + LibSharedMedia
EllesmereUI.GetBorderTextureDropdown()              -- values, order
EllesmereUI.GetBorderStyleSelectDefaults(key)       -- colour, behind, behindUnitFrame
EllesmereUI.GetBorderTextureDefaultThickness(key)   -- "thin"|"normal"|"heavy"|nil
EllesmereUI.ApplyBorderStyle(hostFrame, size, r,g,b,a, textureKey, ...)
EllesmereUI._applyBlizzardConfiguredBorder(owner, prefix, legacySize)  -- also exposed
```

Built-in keys: `solid`, `glow`, `shadow`, `blizz`, `lightspark`, `dialog`, plus any
`sm:<name>` LibSharedMedia border. `size` is a step 1–4 (edge sizes 12/16/24/32).
`hostFrame` must be a frame **you** own. For `shadow`,
`GetBorderStyleSelectDefaults` returns black plus a `behind` flag — seat the host
at `parentLevel - 1`.

Draw your border *outside* the shell's own chrome and switching styles stays live
with no reload.

### There is no "EllesmereUI window border" to inherit

An earlier version of this section said to inherit
`EllesmereUIDB.windowBorderTexture` / `windowBorderSize`. **Those keys do not
exist at the root of `EllesmereUIDB`** — not in 8.6.5, 8.6.6 or 9.2.9 — so a
"match EllesmereUI" border built on them has always resolved to *no border*.
Postbox shipped exactly that bug. The window border those names belong to is the
damage meter's, in the meter's own profile. Every EllesmereUI module owns the
border of its own kind of frame:

| Module | Setting (9.2.9) | Controls | A source for a third-party window? |
|---|---|---|---|
| Damage Meters | `profiles[p].addons.EllesmereUIDamageMeters.dm.windowBorderSize` / `windowBorderTexture` / `windowBorderColor` (default size **0**) | the meter window's frame | No. Default is none; forced to 0 under the meter's Blizzard/Classic look; plenty of players run the meter with no background or border at all. |
| Damage Meters | `dm.borderSize`, `dm.iconBorderSize`, `dm.hdrBottomBorderSize` | bars, icons, header rule | No — bar furniture. |
| Unit Frames | per unit `borderSize` (1), `borderTexture` ("solid"), `borderColor` (black) | a 1px black line hugging each frame | No — every default install has one, so "match" would put a black edge on every window. |
| Action Bars | per bar `borderSize`, `borderThickness`, `borderTexture`, `bgBorderThickness` | button and bar-background borders | No — button furniture. |
| Minimap | `minimap.borderSize`, `borderTexture`, `borderR..A` | the map's frame; dropped under the stock looks | No. |
| Chat | `chat.panelBorderThickness` (default **"none"**), `panelBorderTexture` | the chat panel | No — default none, chat-specific. |
| Resource Bars, Raid Frames, Nameplates, Cooldown Manager, Friends | per element `borderSize` / `borderTexture` | their own bars and icons | No. |
| Bags | — | no user border setting | — |
| Blizz UI Enhanced | account-wide `tooltipBorder*`, `popupMenuBorder*`, `popupMenuButtonBorder*` (Texture, Thickness none…strong, Color, ColorMode, Opacity, offsets, Behind) via `EllesmereUI._applyBlizzardConfiguredBorder(owner, prefix)` | tooltips, context menus, static popups, the game menu | Closest in spirit, but these are popups, not windows, and the module can be disabled. |
| Blizz UI Enhanced windows | none — the fixed `AdventureMap_TopBorder` atlas that `S.Shell` lays down unless `opts.noBorder` | every skinned Blizzard window | This **is** the house window border, and `S.Shell` already draws it. |

So Postbox offers no "match" for the border. An unset border is **None** —
precisely what the broken "match" always drew — and the player can still pick any
texture from the shared engine and a size for it. Nothing needed migrating:
"match" was stored as *unset*, and unset now means the None it always rendered.

---

## 5. Never use Blizzard context menus for addon options

Two independent blockers, both discovered by hitting them:

### `CreateTexture` is disallowed on menu frames

`Blizzard_Menu/Compositor.lua` guards menu frames and hard-errors:

```
Use of function 'CreateTexture' is disallowed (Call).
```

Same for `CreateFontString`, `CreateLine`, `CreateMaskTexture`,
`CreateAnimationGroup`. You cannot add a backdrop of your own to a menu panel.

### `AddMenuAcquiredCallback` taints Blizzard's menu pipeline

The obvious way to reach submenu frames is a documented hazard. EllesmereUI's own
source carries the warning and a field report (2026-07-28): it plants an insecure
Lua function inside Blizzard's menu description, which Blizzard then **calls from
inside its own pipeline**, tainting the code that owns the entry click handlers.
The observed symptom was choosing *Whisper* from a unit menu opening the chat edit
box with a **secret** target name, then failing `SetText` every frame forever.

EllesmereUI's safe pattern, if you must touch menus, is post-hooking
`Menu.GetManager()`'s `OpenMenu` / `OpenContextMenu` and fetching the frame
yourself on staggered `C_Timer.After` passes. Note their own skin only reaches
`GetOpenMenu()` — the **root** — so submenu panels stay unskinned and render with
no background at all.

**Conclusion: own your frames.** Postbox's options panel, dropdowns and contact
picker are all Postbox-owned. They are opaque, skinnable, taint-free, and
mutually exclusive on open.

---

## 6. Practical primitive notes

- **Scroll bars.** `S.ScrollBar` targets `MinimalScrollBar` (`.Track`, `.Back`,
  `.Forward`). `UIPanelScrollFrameTemplate` still builds the *classic* slider,
  which has `GetThumbTexture()` instead. Detect the shape and handle both.
- **Tabs.** `S.Tab` owns the whole visual: it clears native art and hides
  Blizzard's label behind its own mirrored one. Selection is read from
  `tab.isSelected` when the parent is a plain frame. **Re-calling `S.Tab(tab)` on
  an already-skinned tab repaints it** — that is the supported way to drive
  selection from outside. Do not also paint the tab yourself; you will be
  recolouring an invisible label.
- **Idempotency.** Every primitive bails after one table lookup on an
  already-skinned frame, so calling from refresh hooks is fine.
- **Getters are for custom elements only.** Anything with a primitive should use
  the primitive so it tracks future EllesmereUI changes. Never cache getter
  results; re-read or hook `S.OnLooksChanged`.
- **`pcall` success does not mean the primitive ran.** The facade entries are
  late-bound pass-throughs — they resolve the engine function at call time and
  return quietly if it is missing — so a call that painted nothing still reports
  success. This bites where you *retire your own art in favour of the house
  art*: Postbox's tabs install a selection override that hands the entire visual
  to `S.Tab`, and a `S.Tab` that silently did nothing would have left the tabs
  with no art from either side. The observable test is that the primitive draws
  its own plate and its own mirrored label, i.e. **new regions on the frame** —
  count before and after, and if nothing appeared, hand the widget back to your
  own painting intact.
- **Restyling one of EllesmereUI's own frames means following its looks too.**
  Postbox restyles EllesmereUIMinimap's mail button rather than drawing its own
  (see `Core/MinimapButton.lua`). Under Blizzard Style and Classic WoW UI that
  module always draws the **round** map, whatever `shape` its profile stores —
  ask its latched `_ModuleNS.EllesmereUIMinimap.MinimapBlizz()` before trusting
  the stored shape — and Classic dresses the indicators as vanilla ring buttons:
  a 31px button whose icon is clipped by a **16px circular mask**. Art sized from
  the button there is cut to its middle, and the module resizes the icon back on
  every layout pass, so the two fight. Size to the mask.

---

## 7. Verification without a game client

You cannot run WoW from a dev loop, so build cheap mechanical checks:

```bash
pip install luaparser
# parse every .lua; a syntax error means the file silently never loads in-game
```

And cross-check symbols — this catches the class of bug that cost the most time
here:

```python
defined = {m.group(1) for m in re.finditer(r'function Skin\.(\w+)', src)}
called  = {m.group(1) for m in re.finditer(r'\bSkin\.(\w+)\s*\(', src)}
print(sorted(called - defined))   # must be empty
```

### Process lessons

- **A bulk regex replace deleted a whole function** (`Skin.ApplyBorder`) while
  leaving three call sites, because the replaced region silently spanned more than
  intended. Every border setting then threw before doing anything. Prefer targeted
  edits, and run the symbol cross-check after any bulk edit.
- **Fix the pattern, not the instance.** A misaligned panel edge was "fixed" at its
  build-time anchor while a second anchor in the refresh path overwrote it at
  runtime. Grep *every* `SetPoint` against the parent, not just the one you edited.
- **Integer rounding tiles badly.** `math.floor((w - gaps) / 3)` loses up to 2px, so
  the last column never meets the container edge. Derive each column's edges from
  the usable width instead.

---

## 8. Quick reference — what to call

| Need | Call |
|---|---|
| Baseline colour + transparency | `EllesmereUI.GetDarkModeFill()` |
| Accent colour | `S.GetAccentColor()` / `EllesmereUI.ELLESMERE_GREEN` |
| UI font | `S.GetFont()` / `EllesmereUI.GetFontPath("blizzardSkin")` |
| Pixel-perfect 1px border | `EllesmereUI.PP.CreateBorder(frame, r,g,b,a, 1, "OVERLAY", 7)` |
| Glow / shadow / textured border | `EllesmereUI.ApplyBorderStyle(...)` |
| User's configured window border | none exists — see §4 |
| Live accent hook | `S.OnLooksChanged(fn)` (8.6.8+, Blizz UI Enhanced loaded); `EllesmereUI.RegAccent({type="callback", fn=fn})` otherwise |
| Live palette + profile-switch hook | `EllesmereUI.RegisterDarkModeRefresh(fn)` |
| Whole-UI look (9.2.5+) | `EllesmereUI.ProfileWindowSkinLook(GetActiveProfileData(), EllesmereUIDB.fonts)`, else `profiles[p].windowSkinLook`, else `EllesmereUIDB.fonts._styleSlots.active` (§1.3) |
| Is skinning on for me right now | `S.IsEnabled()` (8.6.8+ only) |
| Tooltip / menu / popup palette | `EllesmereUI.RESKIN` |

Everything above except `S.*` and the 9.2.5 look records works on 8.6.6.

### What Postbox does *not* take from the facade, and why

| Available | Postbox uses instead | Reason |
|---|---|---|
| `S.GetPanelColor()` | `EllesmereUI.GetDarkModeFill()` | The panel fill is the window-skin engine's own colour. The Dark Mode fill is the per-profile value the user's *whole* UI shares (§2), including its alpha, which is what §3's transparency drives. |
| `S.GetFont()` | `S.Font(fontString)` on the `api` backend | Prefer the primitive; the getter is only needed for the shim's hand-rolled `Font`. |
| `S.ScrollBar` on Postbox's own lists | hand-rolled classic-slider path | See §6 — Postbox's lists are `UIPanelScrollFrameTemplate`, the wrong shape for that primitive. Nested Blizzard widgets still get the primitive. |
| `S.FadeRegions`, `S.White`, `S.WhiteButtonLabel`, `S.StateButtonLabel`, `S.Dropdown`, `S.PageButton`, `S.SquareIcon`, `S.SortHeaderBar`, `S.ApplyBarFill` | — | No element in Postbox's window matches these. Postbox's dropdowns and pickers are its own frames (§5), not Blizzard templates. |
