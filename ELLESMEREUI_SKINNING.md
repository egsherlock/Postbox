# Skinning an addon for EllesmereUI — findings and lessons

Written while adding EllesmereUI support to Postbox (July 2026, WoW 12.0.7 → 12.1),
and updated on 2026-07-31 against the shipped skinning API in **EllesmereUI
v8.6.8**. Most of this was learned the hard way and is **not** in EllesmereUI's
own developer guide. It should transfer directly to the MountsJournal
EllesmereUI skin and any other addon in the suite's style.

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
- **The pass-throughs are late-bound.** Each looks its primitive up in the
  engine at call time and returns quietly if it is not there. A call that did
  nothing therefore still comes back from `pcall` as a success — see §6 for the
  one place in Postbox where that mattered.

### The two-backend pattern

Postbox ships two backends behind one skinning body, selected at `PLAYER_LOGIN`:

| Backend | When | What it does |
|---|---|---|
| `api` | a facade actually arrives (8.6.8+) | Uses the official facade. EllesmereUI owns every visual. |
| `compat` | 8.6.7 and earlier, or the dispatcher is missing/silent | Rebuilds the same facade from the public helpers 8.6.6 *does* export. |

The switch is automatic on update. `/postbox skin` prints which is live.

**Defer registration to `PLAYER_LOGIN`.** Do not decide at file-load time —
`OptionalDeps` affects load order but a load-time guard bakes in a permanent
no-op if anything is off. At `PLAYER_LOGIN` EllesmereUI is fully initialised
either way, and the API's own dispatcher explicitly supports late registration.

### 1.1 Silence is not one condition — it is three

Register, and your callback may simply never arrive. Answering that with "fall
back to the shim" is wrong in one of the three cases, and it is the case where
being wrong matters most. Postbox waits 5s and then asks two read-only,
nil-guarded questions:

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
- `S.OnLooksChanged` fires for what EllesmereUI counts as looks: accent, bar
  fill, Modern backdrop colour, window styles. A **profile switch** — which moves
  `GetDarkModeFill()`, i.e. Postbox's entire baseline colour *and* its alpha —
  is not on that list, and neither is the window border read straight out of
  `EllesmereUIDB`. Postbox covers both with an `OnShow` hook on each skinned
  window, so close-and-reopen picks them up.

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
restyle completes before the `OnLooksChanged` callbacks fire. If it is the other
way round, the window sits at the host's alpha until the next window open, which
the `OnShow` hook already covers. There is also a case worth watching in game:
if a restyle retires old art by zeroing its alpha rather than hiding it, a
re-applied opacity pass would drive it back up and resurrect the old style under
the new one. Postbox deliberately does **not** guard against this speculatively,
because a guard that misfires during a transient would delete the live backdrop
— a worse bug than the one it prevents. It is on the in-game test list instead.

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
follows profile switches for free. atrocityUI is not doing anything magic — it is
just an EllesmereUI profile that sets these keys.

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

**Inherit the user's choice** rather than picking your own:

```lua
EllesmereUIDB.windowBorderTexture   -- e.g. "solid"
EllesmereUIDB.windowBorderSize      -- 0 means no border
```

Draw your border *outside* the shell's own chrome and switching styles stays live
with no reload.

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
| User's configured window border | `EllesmereUIDB.windowBorderTexture` / `windowBorderSize` |
| Live theme-change hook | `S.OnLooksChanged(fn)` (8.6.8+ only) |
| Is skinning on for me right now | `S.IsEnabled()` (8.6.8+ only) |
| Tooltip / menu / popup palette | `EllesmereUI.RESKIN` |

Everything above except `S.*` works on 8.6.6.

### What Postbox does *not* take from the facade, and why

| Available | Postbox uses instead | Reason |
|---|---|---|
| `S.GetPanelColor()` | `EllesmereUI.GetDarkModeFill()` | The panel fill is the window-skin engine's own colour. The Dark Mode fill is the per-profile value the user's *whole* UI shares (§2), including its alpha, which is what §3's transparency drives. |
| `S.GetFont()` | `S.Font(fontString)` on the `api` backend | Prefer the primitive; the getter is only needed for the shim's hand-rolled `Font`. |
| `S.ScrollBar` on Postbox's own lists | hand-rolled classic-slider path | See §6 — Postbox's lists are `UIPanelScrollFrameTemplate`, the wrong shape for that primitive. Nested Blizzard widgets still get the primitive. |
| `S.FadeRegions`, `S.White`, `S.WhiteButtonLabel`, `S.StateButtonLabel`, `S.Dropdown`, `S.PageButton`, `S.SquareIcon`, `S.SortHeaderBar`, `S.ApplyBarFill` | — | No element in Postbox's window matches these. Postbox's dropdowns and pickers are its own frames (§5), not Blizzard templates. |
