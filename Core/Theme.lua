local _, ns = ...

-- Postbox :: the design system.
--
-- One palette, one surface treatment, one control plate, one set of text roles,
-- one spacing ladder, and the sizing helpers that make a control fit its own
-- translated caption. Everything the UI layer draws sources its colour, font
-- and spacing from this file; nothing below it introduces a colour, surface or
-- font of its own.
--
-- Two rules run through the whole of it, because breaking either one is what
-- the visual defects it was rewritten to fix had in common:
--
--   A control's legibility must not depend on the window's fill. The user owns
--   that fill and may make it nearly transparent; a plate that carries text
--   therefore brings enough opacity of its own to stay readable with the game
--   world behind it. See the plate tokens in section 1.
--
--   There is one accent, and exactly one place that decides what it is
--   (Theme.GetAccent). Nothing paints from the palette's accent constant --
--   even the accent-named tokens resolve through the live accent -- so a
--   host-UI user cannot end up with two accents in one window. See section 1b.
--
-- The foundation layer (Lib/UI/Theme.lua) owns the *painting*. This file owns
-- the *values* and the addon-specific entry points that tag a frame for the
-- optional host-UI skins. The palette here is pushed into the foundation
-- theme's own published tables at load, in place, so every existing consumer of
-- those tables -- including ns.Core.UI.RowStyling's aliases and the shared
-- dropdown's menu colours -- follows automatically.

ns.Theme = ns.Theme or {}
local Theme = ns.Theme

local Helpers    = ns.Core and ns.Core.UI and ns.Core.UI.Helpers or nil
local RowStyling = ns.Core and ns.Core.UI and ns.Core.UI.RowStyling or nil

if ns.Core and ns.Core.UI and ns.Core.UI.Theme and ns.Core.UI.Theme.BindAddon then
  ns.Core.UI.Theme.BindAddon(Theme)
end

local SharedTheme = Theme._sharedTheme

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

-------------------------------------------------------------
-- 1. The palette
--
-- Semantic names only. A caller asks for `accent` or `textSecondary`, never for
-- a number, so re-tinting the addon is one edit here.
--
-- The brand colour is #d3a44a. It was already the chat prefix and appeared
-- nowhere in the UI; the previous build instead carried seven near-identical
-- golds, five greys, and one cool blue-grey row stripe over a warm brown fill.
-- There is now exactly one accent HUE and exactly three text greys.
--
-- WHERE THE ACCENT IS ALLOWED, which is the rule the pass before this one broke:
-- an accent used everywhere is not an accent. Having established one gold, the
-- obvious next move was to put it on everything that had been grey -- every
-- plate ring, every unselected caption, every panel border, every row stripe --
-- and the result was a uniform tan cast over the entire chrome with nothing
-- left for the accent to stand out AGAINST. It also failed the host-UI case
-- badly: an EllesmereUI user's accent could be any hue at all, and an accent on
-- every border puts the whole window under it.
--
-- So: the accent marks MEANING -- the selected state, field captions, section
-- headings and rules, the favourites flag, and the semantic colours (money,
-- errors, warnings). Everything else -- rings, bevels, unselected captions,
-- panel and slot borders, row stripes, grain -- is CHROME, and chrome is
-- neutral. Every warm token below either names a meaning or is a mistake.
--
-- One hue, three tones. The single accent stays, but a control caption needs
-- more than one value of it: the selected member of a group has to beat its
-- unselected siblings by a step the eye reads instantly, and one colour cannot
-- be both the quiet one and the loud one. `accentMuted` was originally the
-- accent DARKENED to 72% of its value, which is not a muting -- on a dark
-- background a darker caption is simply a dimmer caption. It is now a genuine
-- muting: all but desaturated, and lifted to a bright fixed value.
--
-- The eye separates the two tones by CHROMA and not by brightness, which is
-- what makes them work at 12px: `bright` is a pale lit cream, `muted` is a
-- near-white with a whisper of the hue in it, and both are legible on their own
-- terms. Neither is a saturated swatch, and neither is dim.
--
-- All three tones are DERIVED (see Tone, below) rather than written out, so
-- they cannot drift apart, and so the same derivation can be applied to a host
-- UI's accent at paint time -- see section 1b.
-------------------------------------------------------------

local C = {
  -- Brand. Exactly #d3a44a (211, 164, 74) -- the values are written to that
  -- precision so Theme.Hex.accent derives back to "d3a44a" byte for byte.
  accent      = { 0.8275, 0.6431, 0.2902, 1.00 },
  -- Filled from `accent` immediately below. Declared here so the palette still
  -- reads as one table and so Theme.Hex covers them.
  accentBright = { 0, 0, 0, 1.00 },   -- the selected caption of a control group
  -- The quiet member of a pair of accent-toned marks -- Send's inactive
  -- category icons. NOT the unselected plate caption any more: that is
  -- plateCaption, and neutral. See "where the accent is allowed", above.
  accentMuted  = { 0, 0, 0, 1.00 },
  accentText   = { 0, 0, 0, 1.00 },   -- accent used as body/label text
  -- The accent as a wash behind a selected plate, and as a section rule. Both
  -- were low enough to be invisible over the window's own fill; a rule nobody
  -- can see is not a rule.
  --
  -- accentWash is now the ONLY thing that makes a selected plate warm -- the
  -- plate fills below are neutral -- which is what lets a host UI's accent
  -- actually light its own selection instead of lighting a hardcoded brown.
  accentWash  = { 0.8275, 0.6431, 0.2902, 0.14 },
  accentRule  = { 0.8275, 0.6431, 0.2902, 0.34 },
  -- The one accent-coloured RING left in the addon: a plate carrying the
  -- favourites flag. It survives the "does this colour mean something here"
  -- test where the idle and selected rings did not -- "there are favourites
  -- behind this tile" is a fact, and the glyph is too small to carry it -- and
  -- being the only gold ring is what makes it read as one. Held below the
  -- selected ring's weight so selection still wins; see PaintPlate.
  accentEdge  = { 0.8275, 0.6431, 0.2902, 0.45 },

  -- Three text greys. If a fourth is wanted, the design is wrong.
  --
  -- `plateCaption` further down is not a fourth: these three are read against
  -- the WINDOW, whose fill the user owns, and it is read against a plate, whose
  -- fill the plate owns. That is a different problem with a different answer,
  -- and it lives with the other plate chrome for exactly that reason.
  --
  -- Every one of these is read at a glance over bright, busy, moving scenery,
  -- through a window whose fill the user is free to make almost transparent.
  -- The old values were set for a document on an opaque page: secondary at 0.72
  -- and disabled at 0.45 are comfortable on white paper and dim over a snowfield.
  -- Each is raised to leave a margin rather than to pass a threshold.
  textPrimary     = { 1.00, 1.00, 1.00, 1.00 },
  textSecondary   = { 0.82, 0.82, 0.82, 1.00 },
  textDisabled    = { 0.56, 0.56, 0.56, 1.00 },
  -- Ghost text in an empty input. Not a fourth grey: it is textDisabled's
  -- neighbour at reduced alpha and is used for nothing else. It was 0.50 at
  -- alpha 0.65 -- an effective value of about 0.33, which is a hint the user
  -- has to hunt for. Neutral: it was warmed "so it reads as part of the field",
  -- which is a reason to tint a hundred pixels of chrome for no gain.
  textPlaceholder = { 0.60, 0.60, 0.60, 0.90 },

  -- Money and errors. Red means error: postage is not an error and is rendered
  -- textSecondary. C.O.D. is `negative` because it is money leaving the player.
  positive = { 0.2549, 0.8353, 0.3529, 1.00 },
  negative = { 1.0000, 0.2667, 0.2667, 1.00 },
  -- Amber. The compose screen's guidance line has a genuine middle severity --
  -- "this will take an hour to arrive" is not an error and must not be red, but
  -- it is not neutral either. One token, one consumer.
  warning  = { 1.0000, 0.7200, 0.2600, 1.00 },

  -- The one card / popup / list surface. Opaque: at high-but-not-full alpha the
  -- borders of widgets behind bleed through as bright seams, and rows scrolling
  -- behind other content show through.
  surface       = { 0.05, 0.05, 0.06, 1.00 },
  -- The tiled stone grain over that fill, tinted down to the surface's own
  -- value so the panel reads near-black rather than brown. Both skins hide this
  -- texture; on a stock UI it is the only thing keeping a large black rectangle
  -- from looking like a hole. The tint is neutral: the source art is warm
  -- stone, so anything but a neutral multiplier compounds a hue the panel
  -- interior has no reason to have.
  surfaceGrain  = { 0.10, 0.10, 0.10, 1.00 },
  -- The single border colour for card surfaces -- and a border is chrome. This
  -- is the same luminance as the warm brown it replaces (0.37, matched rather
  -- than guessed) at the same alpha, so panels keep exactly the weight of edge
  -- they had and lose only the hue.
  surfaceBorder = { 0.38, 0.38, 0.38, 0.55 },

  -- The totals banner, and only the totals banner. It is a divider, not a
  -- panel: a quiet neutral tint with a lighter neutral border. The figures ON
  -- the band are gold (they are money); the band itself is chrome.
  --
  -- The SAME rule the plate tokens below encode applies here, and this token
  -- broke it for exactly as long as they did. The band was 34% opaque -- a
  -- text-bearing surface carrying the run's gold totals, two thirds of the way
  -- to a hole in the window -- so with the user's own fill turned down the
  -- earned/spent figures were read against whatever the player was standing in
  -- front of. It is now held at the plate opacity FLOOR (0.94), which is what
  -- makes "legible at the most transparent window setting" a property of the
  -- surface rather than a hope about the background.
  --
  -- The value is lowered as the alpha rises, so the band gains substance
  -- without gaining brightness: it stays quieter than plateSelected (it is a
  -- divider, and must never read as the loudest control on the screen) and a
  -- shade above plateIdle, which is what separates it from the plates rather
  -- than merely from the window.
  bandFill   = { 0.078, 0.078, 0.078, 0.94 },
  bandBorder = { 0.47, 0.47, 0.47, 0.50 },

  -- Item slots. The native empty-slot art is the look; nothing opaque goes over
  -- it. slotFill is transparent by definition -- it exists as a token so the
  -- fact that it must stay transparent is written down somewhere.
  slotFill   = { 0.00, 0.00, 0.00, 0.00 },
  slotShade  = { 0.02, 0.02, 0.02, 0.35 },
  -- The same border as a card, and for the same reason: it frames an item icon
  -- that supplies all the colour the slot needs.
  slotBorder = { 0.38, 0.38, 0.38, 0.55 },

  -- Row striping. Neutral, low alpha, each roughly double the previous. A
  -- stripe says "this is a different row", which is a fact about position and
  -- not about the addon, so it takes no hue -- and a warm hover wash laid over
  -- every row the pointer crosses was the largest single area of tan in the
  -- window. The alphas come from the luminance the warm values carried -- 0.72
  -- warm at alpha 0.05 contributes as much light as white at 0.032 -- rounded
  -- up onto the clean doubling ladder, which lands each stripe a shade brighter
  -- than its warm predecessor rather than a shade dimmer. Brighter is the
  -- direction wanted; dimmer would have traded one complaint for another.
  stripeOdd   = { 1.00, 1.00, 1.00, 0.04 },
  stripeEven  = { 1.00, 1.00, 1.00, 0.08 },
  stripeHover = { 1.00, 1.00, 1.00, 0.16 },

  -- Control plates: window tabs, view segments, recipient category tiles.
  --
  -- THE RULE THIS ENCODES: a control's legibility must never depend on the
  -- window's fill. The user owns that fill -- under EllesmereUI it follows the
  -- suite's own opacity setting and can be nearly transparent -- so a control
  -- that carries text has to bring its own ground or its caption ends up
  -- competing with whatever the player happens to be standing in front of.
  --
  -- The previous ladder failed twice over. It signalled prominence by REMOVING
  -- surface: idle was 45% black, hover 28%, selected 15%. So the selected
  -- plate -- the one that matters most and is the one the eye is sent to --
  -- was the most see-through thing on the screen, and at a transparent window
  -- setting the game world rendered straight through it. Prominence must add
  -- substance, never subtract it.
  --
  -- Both channels therefore rise together, idle -> hover -> selected: alpha
  -- 0.94 -> 0.96 -> 0.99 (so even the idle plate is at worst 6% see-through),
  -- and value #0d0d0d -> #171717 -> #222222. The plate stays DARKER than the
  -- caption on it in every state, which is what keeps the contrast steady: a
  -- plate that lightens to signal selection walks its own caption's contrast
  -- down at the same time.
  --
  -- The fills are NEUTRAL, including the selected one, which the pass before
  -- this one made a hardcoded brown (#251c0d) so that selection would read as
  -- "gold-lit". That was wrong twice: it put a brown chip in a window whose
  -- chrome is otherwise grey, and an EllesmereUI user running a blue accent got
  -- a brown plate with a blue wash on it. The lighting now comes entirely from
  -- accentWash, which resolves through the live accent -- so the selected plate
  -- composites to #3b3428 on the brand gold and to the equivalent of whatever
  -- accent the host publishes.
  plateIdle      = { 0.052, 0.052, 0.052, 0.94 },
  plateHover     = { 0.090, 0.090, 0.090, 0.96 },
  plateSelected  = { 0.135, 0.135, 0.135, 0.99 },
  -- A plate carrying a flag its glyph alone is too small to convey -- the
  -- favourites star with something behind it. One step up from idle, no more:
  -- selected still has to win.
  plateFlagged   = { 0.078, 0.078, 0.078, 0.95 },
  -- The 1px ring, at three alphas of one white.
  --
  -- It was warm brown at 0.90 idle, which put a prominent tan ring on every tab,
  -- every switch segment and every category tile at once -- five or six of them
  -- across a 480px window -- and that, more than anything else, is what gave the
  -- whole interface a warm cast. A ring is chrome. It gets no hue.
  --
  -- The idle ring is deliberately barely there (0.20): the plate fill is now
  -- near-opaque and does the work of defining the control, so the ring only has
  -- to stop the fill bleeding into the panel behind it. Prominence still rises
  -- with state, it just rises in alpha rather than in temperature.
  plateEdge         = { 1.00, 1.00, 1.00, 0.20 },
  plateEdgeHover    = { 1.00, 1.00, 1.00, 0.35 },
  plateEdgeSelected = { 1.00, 1.00, 1.00, 0.55 },
  -- A 1px inner line along the top edge. This is the whole of the "weight"
  -- trick: a lit top edge is what the eye reads as a raised, solid chip, and it
  -- costs one texture at a tenth of an alpha. White: a lit edge is a highlight,
  -- and a highlight is the colour of the light, not of the object.
  plateBevel     = { 1.00, 1.00, 1.00, 0.10 },
  -- The HIGHLIGHT-layer wash the client draws on mouse-over by itself. It sits
  -- on top of the hover fill, so it is deliberately slight.
  plateHighlight = { 1.00, 1.00, 1.00, 0.08 },
  -- The caption of an UNSELECTED plate. Bright, and neutral.
  --
  -- Not textSecondary, and not a fourth text grey: this is plate chrome, and it
  -- sits beside plateEdge and plateBevel because it is read against a known,
  -- near-opaque ground rather than against the window. It is the brightest
  -- neutral in the palette after textPrimary on purpose -- an unselected tab is
  -- still a control the user is meant to be able to read at a glance, and the
  -- previous value (accentMuted, a warm grey at 0.67) made every inactive
  -- caption both dimmer and browner than the one it had replaced.
  --
  -- The SELECTED caption is the accent's bright tone and stays that way: which
  -- member of a group is open is exactly the kind of fact the accent is for.
  plateCaption   = { 0.86, 0.86, 0.86, 1.00 },

  -- Unread / read dot on a mail row.
  unread = { 0.20, 0.80, 0.20, 1.00 },
  read   = { 0.40, 0.40, 0.40, 0.60 },
}

Theme.Colors = C

-------------------------------------------------------------
-- 1b. Accent tones, and the one accent
--
-- WHICH accent: the host UI's when a host UI publishes one, the brand gold
-- otherwise -- uniformly, with no exceptions. The previous build was
-- inconsistent about this in a way that showed: the collect screen's view
-- segments painted from Theme.GetAccent() (so they followed the user's
-- EllesmereUI accent) while the window tabs painted from the palette constant
-- (so they stayed Postbox gold), and an EllesmereUI user running a non-gold
-- accent saw two different accents in one window. Everything below routes
-- through GetAccent, and the accent-named palette tokens are resolved through
-- it by Theme.SetColor / Theme.FillColor, so a control cannot pick the wrong
-- one by accident -- including controls in files that only ever pass the token
-- NAME and never touch a colour themselves.
--
-- WHICH TONE: three, derived from whatever that accent turns out to be.
--
--   base    the accent itself. Decorative only -- rules, the selection wash,
--           the selected underline, the favourites ring. Four consumers, all
--           of which mean something; see the note at the head of section 1.
--   text    the accent guaranteed legible as text. Identical to `base` for the
--           brand gold, which is already bright enough; a host accent that is
--           dark (a deep blue, say) is lifted, because a field caption must not
--           become unreadable just because the user likes a dark accent.
--   bright  the selected caption of a control group. Lit, not saturated.
--   muted   the quiet member of a pair of accent-toned marks. Nearly neutral
--           and bright, so the eye separates it from `bright` by CHROMA rather
--           than by one of the two being hard to read.
--
-- Derived, never cached. A repaint is re-driven when the host UI's looks change
-- -- Core/Skin_EllesmereUI.lua's Skin.OnHostLooksChanged, live off the host's
-- own callback on the api backend and at window-show on the compat backend
-- (8.6.6, which is what real users have) -- so a cached tone would be stale from
-- the moment the user retuned their accent. The arithmetic is a dozen
-- operations and runs only on repaint.
-------------------------------------------------------------

-- Scaled until its brightest channel is white, then blended most of the way to
-- white again. The result is a PALE, lit version of the accent rather than a
-- saturated one: it lands on #ffe7b9 for the brand gold, a cream that reads as
-- "this caption is lit" instead of "this caption is yellow".
--
-- It used to stop at 0.96 peak and a tenth of a blend, which produced #f6c567 --
-- a fully saturated gold, on the selected member of every control group at
-- once. Loud is the job; saturated is not. A caption is small text, and small
-- saturated text on a dark plate reads as coloured before it reads as words.
local function ToneBright(r, g, b)
  local peak = max(r, g, b)
  local k = (peak > 0.01) and (1.00 / peak) or 1
  r, g, b = min(1, r * k), min(1, g * k), min(1, b * k)
  return r + (1 - r) * 0.58, g + (1 - g) * 0.58, b + (1 - b) * 0.58
end

-- Nearly all the way to the neutral of its own luminance -- a whisper of the hue
-- survives, the chroma does not -- then lifted to a fixed value so a quiet
-- accent is exactly as legible whatever accent the host publishes. The brand
-- gold lands on #dbd8d1, which is within a few levels of plateCaption (#dbdbdb)
-- and deliberately so: the two are used side by side (a Send-tab category bar
-- mixes captioned tiles with icon-only ones) and they must not read as two
-- different greys.
--
-- It was 0.78 desaturated and held at 0.672, i.e. #aba18e -- a warm grey, and a
-- dim one. Both halves of that showed: warm because it was on every inactive
-- caption in the window, dim because 0.672 against a 0.86 caption elsewhere on
-- the same screen reads as disabled.
local function ToneMuted(r, g, b)
  local lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
  r = r + (lum - r) * 0.94
  g = g + (lum - g) * 0.94
  b = b + (lum - b) * 0.94
  local peak = max(r, g, b)
  local k = (peak > 0.01) and (0.86 / peak) or 1
  return min(1, r * k), min(1, g * k), min(1, b * k)
end

-- A floor, not a transform: an accent already bright enough to read as text is
-- returned untouched, so the brand gold is unchanged byte for byte.
local function ToneText(r, g, b)
  local peak = max(r, g, b)
  if peak >= 0.80 then return r, g, b end
  local k = (peak > 0.01) and (0.80 / peak) or 1
  return min(1, r * k), min(1, g * k), min(1, b * k)
end

local function StoreTone(color, r, g, b)
  color[1], color[2], color[3] = r, g, b
end

StoreTone(C.accentBright, ToneBright(C.accent[1], C.accent[2], C.accent[3]))
StoreTone(C.accentMuted,  ToneMuted(C.accent[1], C.accent[2], C.accent[3]))
StoreTone(C.accentText,   ToneText(C.accent[1], C.accent[2], C.accent[3]))

-- Colour-escape strings, derived from the palette so there is still only one
-- source. Used where text has to be coloured inside a concatenated string
-- (money lines, C.O.D. markers) rather than on a whole font string.
--
-- These stay on the BRAND, deliberately: a chat line the user copies out of the
-- log should not change colour because they retuned their UI, and the escape is
-- baked into a string at the moment it is built rather than repainted.
local Hex = {}
Theme.Hex = Hex

local function ToHex(color)
  return ("%02x%02x%02x"):format(
    floor((color[1] or 0) * 255 + 0.5),
    floor((color[2] or 0) * 255 + 0.5),
    floor((color[3] or 0) * 255 + 0.5))
end

for token, color in pairs(C) do
  Hex[token] = ToHex(color)
end

-- "|cffd3a44atext|r". An unknown token returns the text unchanged rather than
-- rendering a broken escape.
function Theme.Colorize(token, text)
  local hex = Hex[token]
  if not hex then return tostring(text or "") end
  return "|cff" .. hex .. tostring(text or "") .. "|r"
end

-- The live accent: a host-UI skin may publish the user's own. Resolved on every
-- call and never cached -- Skin.OnHostLooksChanged re-drives the repaints (live
-- on the EllesmereUI api backend, at window-show on compat), and a cached copy
-- would be stale from the moment the user retuned their accent.
--
-- This is the ONLY place the question "which accent" is answered. Nothing else
-- reads C.accent to paint with.
function Theme.GetAccent()
  local skin = ns.Skin
  if skin and type(skin.GetAccent) == "function" then
    local r, g, b = skin.GetAccent()
    if r then return r, g, b end
  end
  return C.accent[1], C.accent[2], C.accent[3]
end

-- The live accent in one of the tones described in section 1b:
-- "base" (default) | "text" | "bright" | "muted".
function Theme.GetAccentTone(tone)
  local r, g, b = Theme.GetAccent()
  if tone == "bright" then return ToneBright(r, g, b) end
  if tone == "muted"  then return ToneMuted(r, g, b) end
  if tone == "text"   then return ToneText(r, g, b) end
  return r, g, b
end

-- The accent-named palette tokens, and how each resolves against the LIVE
-- accent. Every one of them is a tone plus an alpha; the palette entries of the
-- same names exist so Theme.Colors and Theme.Hex stay complete, but Theme.SetColor
-- and Theme.FillColor answer from here, which is what makes a caller that only
-- knows the token name -- and there are several, in files that never see a
-- colour -- follow the host accent for free.
local ACCENT_TOKENS = {
  accent       = { "base",   1.00 },
  accentText   = { "text",   1.00 },
  accentBright = { "bright", 1.00 },
  accentMuted  = { "muted",  1.00 },
  accentWash   = { "base",   C.accentWash[4] },
  accentRule   = { "base",   C.accentRule[4] },
  accentEdge   = { "base",   C.accentEdge[4] },
}

-- Text wants the legible tone; a rule or a ring wants the accent as it is. Both
-- come from the one token so no caller has to know the difference.
local function ResolveAccentToken(token, asText)
  local spec = ACCENT_TOKENS[token]
  if not spec then return nil end
  local tone = spec[1]
  if asText and tone == "base" then tone = "text" end
  local r, g, b = Theme.GetAccentTone(tone)
  return r, g, b, spec[2]
end

-------------------------------------------------------------
-- 2. Push the palette into the foundation theme
--
-- Lib/UI/Theme.lua publishes Palette / RowColors / MenuColors "as data so a
-- host-UI skin can read or override it". This is that override, done in place
-- so the aliases held elsewhere (RowStyling.ROW_COLOR_*) point at the same
-- tables and follow without being reassigned.
-------------------------------------------------------------

local function Recolor(dest, src)
  if type(dest) ~= "table" or type(src) ~= "table" then return end
  dest[1], dest[2], dest[3], dest[4] = src[1], src[2], src[3], src[4]
end

if SharedTheme then
  local palette = SharedTheme.Palette
  if type(palette) == "table" then
    -- `list` and `card` are now the same surface. They stay as two names
    -- because the foundation layer's variant argument is a string, not because
    -- they differ.
    for _, name in ipairs({ "list", "card" }) do
      local scheme = palette[name]
      if type(scheme) == "table" then
        Recolor(scheme.bg, C.surface)
        Recolor(scheme.border, C.surfaceBorder)
        scheme.surface = true
      end
    end
    if type(palette.controls) == "table" then
      Recolor(palette.controls.bg, C.bandFill)
      Recolor(palette.controls.border, C.bandBorder)
      palette.controls.surface = false
    end
  end

  local rows = SharedTheme.RowColors
  if type(rows) == "table" then
    Recolor(rows.odd, C.stripeOdd)
    Recolor(rows.even, C.stripeEven)
    Recolor(rows.hover, C.stripeHover)
  end

  -- The shared dropdown's list panel is the third of the three popups the audit
  -- found wearing three different surfaces. It now wears this one.
  local menu = SharedTheme.MenuColors
  if type(menu) == "table" then
    Recolor(menu.fill, C.surface)
    Recolor(menu.border, C.surfaceBorder)
    Recolor(menu.hover, C.stripeHover)
  end
end

-------------------------------------------------------------
-- 3. Text roles
--
-- A role says what the text *means*. The font object follows from that.
--
-- The rule this exists to enforce: secondary metadata is highlight-small tinted
-- textSecondary, never the disabled font object. The previous build rendered
-- the mail row's money / C.O.D. / expiry line, the detail info line and the
-- screen hint in GameFontDisableSmall, so the most information-dense line on
-- screen read as inactive. `disabled` is for controls that genuinely cannot be
-- used, and nothing else.
-------------------------------------------------------------

local TEXT_ROLES = {
  title       = { font = "GameFontNormalLarge",    color = "textPrimary" },
  heading     = { font = "GameFontNormalSmall",    color = "accent" },
  label       = { font = "GameFontNormalSmall",    color = "accent" },
  -- Tabs, view segments and category tiles: accentBright when selected,
  -- plateCaption -- a bright neutral -- when not. Apply the role, then re-tint
  -- with Theme.SetColor on selection, or let Theme.CreatePlate do both, which
  -- is what it is for.
  --
  -- The unselected state is the one carrying the colour rule: five tiles, two
  -- tabs and a pair of view segments are on screen together, so whatever colour
  -- "not selected" is, it is most of the text in the window. It is therefore
  -- neutral, and the accent is left to mark the one that is selected.
  --
  -- `segment` was GameFontHighlightSmall (10px). A caption on a control is not
  -- metadata; at 10px on a 22px plate it read as a word floating on the panel
  -- rather than as the control's own label, which is half of "the tiles look
  -- thin". At 12px it fills its plate. The tiles that use this role are all
  -- measured from the rendered string and truncate with a tooltip when a
  -- translation still will not fit, so the extra two points cannot clip
  -- anything -- see Theme.FitText and Theme.LayoutRow.
  tab         = { font = "GameFontNormal",         color = "plateCaption" },
  segment     = { font = "GameFontNormal",         color = "plateCaption" },
  body        = { font = "GameFontHighlight",      color = "textPrimary" },
  bodySmall   = { font = "GameFontHighlightSmall", color = "textPrimary" },
  value       = { font = "GameFontHighlightSmall", color = "textPrimary" },
  secondary   = { font = "GameFontHighlightSmall", color = "textSecondary" },
  placeholder = { font = "GameFontHighlightSmall", color = "textPlaceholder" },
  disabled    = { font = "GameFontDisableSmall",   color = "textDisabled" },
  number      = { font = "NumberFontNormal",       color = "textPrimary" },
  numberSmall = { font = "NumberFontNormalSmall",  color = "textPrimary" },
}

Theme.TextRoles = TEXT_ROLES

local FONT_FALLBACK = { "GameFontHighlightSmall", "GameFontHighlight", "GameFontNormal" }

-- role -> a font object that exists on this client, or nil. The TOC declares two
-- interface versions and the number fonts in particular are not guaranteed.
function Theme.FontObject(role)
  local spec = TEXT_ROLES[role] or TEXT_ROLES.bodySmall
  local object = _G[spec.font]
  if object then return object, spec end
  for i = 1, #FONT_FALLBACK do
    object = _G[FONT_FALLBACK[i]]
    if object then return object, spec end
  end
  return nil, spec
end

-- Font strings currently wearing an accent token -> that token.
--
-- A TEXTURE painted from an accent token is repainted by whatever owns it: a
-- plate repaints from its own state, and the EllesmereUI skin sweeps the window
-- for plates when the user's accent changes. A FONT STRING had nothing doing
-- that job -- SetTextColor writes a colour and forgets which token produced it
-- -- so every accent-toned heading, field caption and tile label kept the old
-- accent until something happened to re-apply its role. This table is the
-- missing half, and Theme.RepaintAccentText is what reads it.
--
-- Weak-keyed, so listing a font string here never keeps a discarded frame's
-- text alive. The entry is rewritten on EVERY SetColor, including to nil when
-- the new token is not an accent one, so a font string can never be repainted
-- to an accent it no longer wears.
local accentTexts = setmetatable({}, { __mode = "k" })

-- Tints an existing region: text colour on a font string, vertex colour on a
-- texture that already has art. Alpha is carried.
--
-- Textures answer to both SetVertexColor and SetColorTexture and they are not
-- interchangeable -- tinting a texture with no art shows nothing at all -- so a
-- solid fill has its own entry point below rather than being guessed at here.
function Theme.SetColor(region, token)
  if not region then return end

  local isText = type(region.SetTextColor) == "function"
  local r, g, b, a = ResolveAccentToken(token, isText)
  if isText then accentTexts[region] = r and token or nil end
  if not r then
    local color = C[token]
    if not color then return end
    r, g, b, a = color[1], color[2], color[3], color[4] or 1
  end

  if isText then
    region:SetTextColor(r, g, b, a)
  elseif type(region.SetVertexColor) == "function" then
    region:SetVertexColor(r, g, b, a)
  end
end

-- Re-tints every accent-toned font string from the LIVE accent.
--
-- Nothing to do on the default theme, where the accent is a constant; this
-- exists for the moment an EllesmereUI user retunes their accent, which
-- Skin.OnHostLooksChanged turns into one call. Bounded by the number of
-- accent-toned font strings on screen -- headings, field captions, tile
-- captions -- which is a couple of dozen, not by the number of font strings.
--
-- Iterating without mutating: SetTextColor is called directly rather than
-- through Theme.SetColor, so the registry cannot be rewritten mid-traversal.
function Theme.RepaintAccentText()
  for region, token in pairs(accentTexts) do
    local r, g, b, a = ResolveAccentToken(token, true)
    if r and type(region.SetTextColor) == "function" then
      region:SetTextColor(r, g, b, a)
    end
  end
end

-- Paints a texture as a flat colour block.
function Theme.FillColor(texture, token)
  if not texture or type(texture.SetColorTexture) ~= "function" then return end

  local r, g, b, a = ResolveAccentToken(token, false)
  if not r then
    local color = C[token]
    if not color then return end
    r, g, b, a = color[1], color[2], color[3], color[4] or 1
  end

  texture:SetColorTexture(r, g, b, a)
end

-- Applies a role's font object and colour to an existing font string.
function Theme.ApplyTextRole(fontString, role)
  if not fontString then return end
  local object, spec = Theme.FontObject(role)
  if object and type(fontString.SetFontObject) == "function" then
    fontString:SetFontObject(object)
  end
  -- Colour goes on the font string, never on the shared font object, so it can
  -- never bleed onto every other user of that object.
  if spec then Theme.SetColor(fontString, spec.color) end
end

-- The preferred way to make text: one call, correct font object and colour.
function Theme.CreateText(parent, role, layer)
  if not parent or type(parent.CreateFontString) ~= "function" then return nil end
  local spec = TEXT_ROLES[role] or TEXT_ROLES.bodySmall
  local fontString = parent:CreateFontString(nil, layer or "OVERLAY", spec.font)
  if not fontString then return nil end
  Theme.ApplyTextRole(fontString, role)
  return fontString
end

-------------------------------------------------------------
-- 4. Metrics
--
-- A spacing ladder, a set of control heights, and the scroll gutter.
--
-- SPACING. "One gap unit" was too few. A form built on a single gap is an even
-- stack of controls: nothing in the spacing says which caption belongs to which
-- field, or where one group of fields ends and the next begins, so the reader
-- has to work that out from the words. Grouping by proximity is free and it is
-- the cheapest structure a form can have -- but only if the gap INSIDE a group
-- is unmistakably smaller than the gap BETWEEN groups.
--
-- Hence a ladder, and three names for what a vertical gap MEANS. The ladder's
-- steps are far enough apart that no two can be mistaken for each other, which
-- is the whole point: a number not on the ladder is a bug, and a number one
-- step off is visible.
--
-- How a screen applies it, top to bottom through a form:
--
--   caption                 <- Theme.CreateText(parent, "label")
--     labelGap (2)             a caption and its field are ONE thing
--   field
--     fieldGap (8)             the next field in the same group
--   caption
--     labelGap (2)
--   field
--     sectionGap (14)          a different group: money, attachments, send
--   section heading
--
-- `inset` is what a panel gives up to its own edge, on both axes. `gap` is the
-- default step between two siblings that are merely adjacent, on either axis --
-- it is the same number as `fieldGap` and deliberately so; `fieldGap` exists to
-- say what a vertical one means, not to be a different value.
-------------------------------------------------------------

-- The ladder. Roughly x1.4 a step above `tight`, which is the closest two
-- spacings can sit and still be told apart at a glance.
local SPACE = {
  hair    = 2,   -- a caption and the field it names; a control's own hairline
  tight   = 4,   -- two lines of one block; padding inside a control
  snug    = 6,   -- two controls acting as one unit (the segments of a switch)
  base    = 8,   -- the default step between siblings, either axis
  panel   = 10,  -- what a panel gives up to its own edge
  group   = 14,  -- one group of fields to the next
  section = 20,  -- one region of a screen to the next
}

Theme.Space = SPACE

-- The classic scroll bar (UIPanelScrollFrameTemplate) anchors itself outside its
-- scroll frame's right edge, so a gutter narrower than the sum below puts the
-- bar on top of the container's border art. The previous build used four
-- different widths -- 22, 24, 24 and 26 -- for one bar; 22 was the one over the
-- art. Derived, not chosen:
local SCROLLBAR_OFFSET    = 6   -- how far outside the scroll frame the bar sits
local SCROLLBAR_WIDTH     = 16  -- the bar's own width
local SCROLLBAR_CLEARANCE = 4   -- room left between the bar and the panel edge

Theme.Metrics = {
  space = SPACE,

  -- Panel edges and stacking. `inset` was 8 while the compose screen used its
  -- own hardcoded 10, so the two tabs' content did not start at the same x and
  -- neither lined up with the tab bar above them. 10 is now the one answer.
  inset    = SPACE.panel,
  gap      = SPACE.base,
  tightGap = SPACE.tight,

  -- The vertical rhythm of a form, named by what each gap means. See above.
  labelGap   = SPACE.hair,
  fieldGap   = SPACE.base,
  sectionGap = SPACE.group,

  -- Control heights. One height for every control class was too blunt: a flat
  -- category tile, a segment of a switch and a push button with a caption do
  -- not want the same weight, and standardising them onto 22 took presence off
  -- all three. Four heights, each named for the class it serves, and each one
  -- step apart so the hierarchy is legible without being fussy.
  --
  -- controlHeight stays the name for "an inline control sitting beside a
  -- field", because that is what its consumers are; it is the same number as
  -- segmentHeight and that is not a coincidence.
  tileHeight    = 22,   -- a flat tile in a dense bar: the lightest control
  controlHeight = 24,   -- an inline control beside a field (was 22)
  segmentHeight = 24,   -- one segment of a segmented switch
  buttonHeight  = 26,   -- a push button carrying a caption
  tabHeight     = 28,   -- a window tab: the heaviest control on screen (was 26)

  rowHeight     = 44,
  listRowHeight = 18,

  iconSize = 14,
  slotSize = 36,

  -- Scrolling.
  scrollBarOffset    = SCROLLBAR_OFFSET,
  scrollBarWidth     = SCROLLBAR_WIDTH,
  scrollBarClearance = SCROLLBAR_CLEARANCE,
  scrollGutter       = SCROLLBAR_OFFSET + SCROLLBAR_WIDTH + SCROLLBAR_CLEARANCE,

  -- Measured sizing defaults (see section 5). buttonMinWidth was 56, which let
  -- a two-segment switch collapse to a pair of stubs next to a full-width field
  -- above it; 64 is the narrowest a captioned control looks deliberate at.
  buttonPadding    = 22,
  buttonPaddingMin = 10,
  buttonMinWidth   = 64,
  tileMinWidth     = 40,
}

local M = Theme.Metrics

-------------------------------------------------------------
-- 5. Measured sizing
--
-- German and Russian strings are materially longer than English. A fixed width
-- combined with word wrap switched off is what clipped them, and both halves of
-- that combination are banned together. Nothing whose caption comes from a
-- locale may carry a constant width.
--
-- Typical use, a row of buttons that must stay even and must fit:
--
--   local per = Theme.LayoutRow(buttons, panel:GetWidth() - 2 * M.inset,
--                               { minWidth = 80 })
--
-- Typical use, one control:
--
--   Theme.SizeToText(button, { minWidth = 80, maxWidth = 160 })
--
-- Typical use, a grid whose columns must meet the container edge exactly:
--
--   local cols = Theme.ColumnEdges(usableWidth, 3, M.gap)
--   button:SetPoint("LEFT", parent, "LEFT", cols[i].left, 0)
--   button:SetWidth(cols[i].width)
-------------------------------------------------------------

-- The rendered width of a widget's caption, or of a font string itself. Returns
-- 0 for anything with no text, which is never a reason to fail.
function Theme.TextWidth(widget)
  if not widget then return 0 end
  local fontString = widget
  if type(widget.GetFontString) == "function" then
    fontString = widget:GetFontString() or widget
  end
  if type(fontString.GetStringWidth) ~= "function" then return 0 end
  local width = fontString:GetStringWidth()
  return (type(width) == "number" and width > 0) and width or 0
end

local function Bounds(opts)
  opts = type(opts) == "table" and opts or nil
  local padding  = (opts and tonumber(opts.padding))  or M.buttonPadding
  local minWidth = (opts and tonumber(opts.minWidth)) or M.buttonMinWidth
  local maxWidth = opts and tonumber(opts.maxWidth) or nil
  return padding, minWidth, maxWidth, opts
end

local function Clamp(width, minWidth, maxWidth)
  width = max(width, minWidth)
  if maxWidth then width = min(width, maxWidth) end
  return floor(width + 0.5)
end

-- Sizes one control from its own rendered caption. Applies opts.height too when
-- one is given, so a row can be made even in one call.
function Theme.SizeToText(widget, opts)
  if not widget or type(widget.SetWidth) ~= "function" then return 0 end
  local padding, minWidth, maxWidth, options = Bounds(opts)
  local width = Clamp(Theme.TextWidth(widget) + padding, minWidth, maxWidth)
  widget:SetWidth(width)
  local height = options and tonumber(options.height)
  if height and type(widget.SetHeight) == "function" then widget:SetHeight(height) end
  return width
end

-- Sizes a row of related controls to their LONGEST member and gives them all
-- that width, so the row stays visually even. Returns the per-control width and
-- the row's total including gaps.
function Theme.SizeRow(widgets, opts)
  if type(widgets) ~= "table" or #widgets == 0 then return 0, 0 end
  local padding, minWidth, maxWidth, options = Bounds(opts)
  local gap = (options and tonumber(options.gap)) or M.gap

  local longest = 0
  for i = 1, #widgets do
    longest = max(longest, Theme.TextWidth(widgets[i]))
  end

  local per = Clamp(longest + padding, minWidth, maxWidth)
  local height = options and tonumber(options.height)
  for i = 1, #widgets do
    local widget = widgets[i]
    if widget and type(widget.SetWidth) == "function" then
      widget:SetWidth(per)
      if height and type(widget.SetHeight) == "function" then widget:SetHeight(height) end
    end
  end

  return per, per * #widgets + gap * (#widgets - 1)
end

-- Column edges derived from the usable width, so the last column lands exactly
-- on the container edge. Flooring one column width instead discards up to a
-- pixel per column and the right-hand margin visibly shifts as the window
-- resizes. `out` is reused when supplied, so a resize handler allocates nothing.
function Theme.ColumnEdges(available, count, gap, out)
  count = floor(tonumber(count) or 0)
  out = type(out) == "table" and out or {}
  for i = #out, count + 1, -1 do out[i] = nil end
  if count < 1 then return out end

  available = tonumber(available) or 0
  gap = tonumber(gap) or M.gap

  local span = available - gap * (count - 1)
  if span < count then span = count end

  for i = 1, count do
    local left  = floor(span * (i - 1) / count + 0.5) + gap * (i - 1)
    local right = floor(span * i / count + 0.5) + gap * (i - 1)
    local column = out[i]
    if type(column) ~= "table" then column = {}; out[i] = column end
    column.left, column.right, column.width = left, right, right - left
  end

  return out
end

-- The full fit rule, in the order the spec requires:
--   1. measure, and size the row to its longest member;
--   2. if the row does not fit, reduce padding to the declared minimum;
--   3. if it still does not fit, wrap the row onto more lines;
--   4. only if opts.truncate is set, and only then, narrow the controls and
--      report that their captions must be truncated with a tooltip.
-- Never clips.
--
-- Returns perWidth, lines, truncated.
function Theme.LayoutRow(widgets, available, opts)
  if type(widgets) ~= "table" or #widgets == 0 then return 0, 0, false end
  local count = #widgets
  local padding, minWidth, maxWidth, options = Bounds(opts)
  local gap        = (options and tonumber(options.gap)) or M.gap
  local minPadding = (options and tonumber(options.minPadding)) or M.buttonPaddingMin
  local maxLines   = (options and tonumber(options.maxLines)) or count
  available = tonumber(available) or 0

  local longest = 0
  for i = 1, count do
    longest = max(longest, Theme.TextWidth(widgets[i]))
  end

  local function fits(width, perLine)
    return width * perLine + gap * (perLine - 1) <= available
  end

  local per = Clamp(longest + padding, minWidth, maxWidth)
  local lines, perLine = 1, count
  local truncated = false

  if not fits(per, perLine) then
    per = Clamp(longest + minPadding, minWidth, maxWidth)
  end

  while not fits(per, perLine) and lines < maxLines do
    lines = lines + 1
    perLine = ceil(count / lines)
  end

  if not fits(per, perLine) then
    if options and options.truncate then
      local room = floor((available - gap * (perLine - 1)) / perLine)
      per = max(room, (options and tonumber(options.floorWidth)) or M.tileMinWidth)
      truncated = true
    end
    -- Without opts.truncate the row keeps its measured width and overflows its
    -- container. That is deliberate: an overflowing row is visible and gets
    -- fixed, a silently clipped caption is not.
  end

  local height = options and tonumber(options.height)
  for i = 1, count do
    local widget = widgets[i]
    if widget and type(widget.SetWidth) == "function" then
      widget:SetWidth(per)
      if height and type(widget.SetHeight) == "function" then widget:SetHeight(height) end
    end
  end

  return per, lines, truncated
end

-- Sets text on a font string constrained to `width`, and records the full text
-- on `owner.__pbOverflowText` when it did not fit (nil when it did). The owner's
-- own OnEnter then calls Theme.AddOverflowLine -- this helper deliberately does
-- not install scripts, because every widget that needs it already has its own
-- OnEnter and silently replacing it is how tooltips go missing.
--
-- Returns true when the caption was truncated.
function Theme.FitText(fontString, width, text, owner)
  if not fontString or type(fontString.SetText) ~= "function" then return false end
  text = tostring(text or "")
  fontString:SetText(text)
  if type(fontString.SetWordWrap) == "function" then fontString:SetWordWrap(false) end

  width = tonumber(width) or 0
  if width > 0 and type(fontString.SetWidth) == "function" then
    fontString:SetWidth(width)
  end

  local truncated = width > 0 and Theme.TextWidth(fontString) > width
  if owner then owner.__pbOverflowText = truncated and text or nil end
  return truncated
end

-- Adds the recorded overflow text to the tooltip. No-op when nothing was cut.
function Theme.AddOverflowLine(owner, tooltip)
  local text = owner and owner.__pbOverflowText
  if not text then return false end
  tooltip = tooltip or GameTooltip
  if not tooltip or type(tooltip.AddLine) ~= "function" then return false end
  tooltip:AddLine(text, 1, 1, 1, true)
  return true
end

-------------------------------------------------------------
-- 6. Surfaces
--
-- There is one card / popup / list surface and one band. Every route to a
-- themed container goes through one of the four entry points below, and each of
-- them sets `__postboxPanel` before delegating -- which is what makes it
-- impossible to build a themed surface a host-UI skin cannot find.
--
-- Consumers of the card surface: the mail list container, the mail detail view,
-- the type-ahead suggestion popup, the contact picker, every input wrap, and
-- the shared select control's list panel (which reads MenuColors, recoloured in
-- section 2). They were three different backgrounds and two different border
-- colours; they are now one.
--
-- Item slots are NOT panels and must not be tagged. See Theme.ApplySlot.
-------------------------------------------------------------

-- The addon's own white tile, not Interface\Buttons\WHITE8x8: structural
-- fills must survive a UI pack's loose-file texture overrides (see
-- Lib/UI/Theme.lua).
local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"

-- A 1px border, as the design calls for. The foundation layer's default is the
-- tooltip nine-slice, whose 12px textured brown edge is a second border colour
-- that no palette token describes.
local SURFACE_BACKDROP = {
  bgFile   = WHITE,
  edgeFile = WHITE,
  edgeSize = 1,
  insets   = { left = 1, right = 1, top = 1, bottom = 1 },
}

local SLOT_BACKDROP = {
  -- No bgFile: the native empty-slot art underneath is the look.
  edgeFile = WHITE,
  edgeSize = 1,
}

local function PaintSurface(frame, variant, tag)
  if not frame then return end

  -- Set before delegating, so a delegation that fails still leaves the frame
  -- findable by both skins.
  frame.__postboxPanel = tag

  if Helpers and Helpers.ApplyThemedBackdrop then
    Helpers.ApplyThemedBackdrop(frame, SharedTheme, variant, false, SURFACE_BACKDROP)
  end

  -- The foundation layer creates the grain in its own warm-stone tint, which is
  -- the window shell's identity rather than a panel interior's. Re-tint it to
  -- the palette. Cheap and idempotent; both skins zero this texture anyway.
  local grain = frame.pbSurfaceTexture
  if grain and type(grain.SetVertexColor) == "function" then
    local tint = C.surfaceGrain
    grain:SetVertexColor(tint[1], tint[2], tint[3], tint[4])
  end
end

-------------------------------------------------------------
-- THE POPUP OPACITY FLOOR
--
-- A popup covers the window it belongs to. Everything underneath it -- a scroll
-- bar, a row of text, the field it was opened from -- is content the reader has
-- already been given, and a popup that lets it through is asking them to read
-- two things in the same rectangle.
--
-- On a stock UI the card surface is opaque and that is the end of it. Under a
-- host-UI skin it is not: EllesmereUI paints our panels with its own primitive
-- at the user's background opacity, so the contact picker and the type-ahead
-- list came out as see-through as the window -- which is the addon's own rule
-- ("a control must stay legible at any window opacity") broken by the surface
-- that needs it most.
--
-- The fix is a floor rather than an override, and it is laid down from OUR side:
-- a plain fill at the very bottom of the popup's own draw order, below anything
-- a skin adds. Whatever the skin then paints on top composites over an opaque
-- ground, so the popup is at least POPUP_FLOOR_ALPHA opaque no matter what the
-- user's opacity setting is, and the skin still owns everything visible.
--
-- Not an alpha override on the skin's art: that is the skin's to set, it moves
-- with the user's slider, and fighting it would put us in a loop with the host's
-- own refresh passes.
--
-- WHICH SURFACES. A card that FLOATS -- toplevel, or raised out of its parent's
-- strata -- is a popup by construction, and all three of Postbox's are built
-- that way before they are painted. Detected here rather than declared at each
-- call site because one of them is Lib/UI/Dropdown.lua, which resolves
-- `ns.Theme.ApplyCard` by name from the foundation layer and cannot be expected
-- to know what the addon considers a popup. Cards that do NOT float -- the mail
-- detail view, every input wrap -- are part of the window's own surface and keep
-- following the user's opacity, which is what that setting is for.
-------------------------------------------------------------

local POPUP_FLOOR_ALPHA = 0.95

local STRATA_RANK = {
  BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
  DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

local function Floats(frame)
  if type(frame.IsToplevel) == "function" and frame:IsToplevel() then return true end

  local parent = type(frame.GetParent) == "function" and frame:GetParent() or nil
  if not parent then return false end
  if type(frame.GetFrameStrata) ~= "function" or type(parent.GetFrameStrata) ~= "function" then
    return false
  end

  return (STRATA_RANK[frame:GetFrameStrata()] or 0) > (STRATA_RANK[parent:GetFrameStrata()] or 0)
end

-- The host's own window fill where there is one, so the floor is the colour the
-- skin would have used and not a Postbox grey showing through its panel art.
-- Re-resolved on every paint: EllesmereUI's baseline moves on a profile switch.
local function PopupFloorColor()
  local skin = ns.Skin
  if skin and type(skin.GetHostBaseline) == "function" then
    local ok, r, g, b = pcall(skin.GetHostBaseline)
    if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
      return r, g, b
    end
  end
  local fill = C.surface
  return fill[1], fill[2], fill[3]
end

local function PaintPopupFloor(frame)
  local art = frame and frame.__pbPopupFloor
  if not art then return end
  local r, g, b = PopupFloorColor()
  art:SetColorTexture(r, g, b, POPUP_FLOOR_ALPHA)
  -- Region alpha and colour alpha MULTIPLY, so the colour above is only half of
  -- it: anything that has faded this region would otherwise survive a repaint.
  art:SetAlpha(1)
end

-- THE FLOOR LIVES ON A HOLDER OF ITS OWN, one frame level below the popup, and
-- that is not tidiness -- it is the only way it survives.
--
-- A host skin's first act on one of our panels is to fade every TEXTURE REGION
-- the frame owns to alpha 0, so that its own art is the only thing drawn
-- (Core/Skin_EllesmereUI.lua, ShimFadeRegions). A floor created directly on the
-- popup is one of those regions, and the sweep runs on the first refresh after
-- the popup exists -- which, for the contact picker, is while it is open.
-- Re-asserting on the next OnShow would leave the first open of each popup
-- without a floor, every session.
--
-- A region of a CHILD frame is not a region of the popup, so the sweep never
-- reaches it; a child one level below its parent draws beneath everything the
-- parent and the skin put on the parent. Mouse is left disabled, so the holder
-- is not in the way of anything.
local function PinPopupOpacity(frame)
  if type(frame.CreateTexture) ~= "function" then return end

  if not frame.__pbPopupFloor then
    local level = tonumber((frame.GetFrameLevel and frame:GetFrameLevel())) or 1
    local holder = CreateFrame("Frame", nil, frame)
    holder:SetAllPoints(frame)
    holder:SetFrameLevel(max(0, level - 1))
    -- The `__pb` name keeps the pair out of EllesmereUI's host-art sweep in the
    -- other direction too, should a popup ever be registered as a window of its
    -- own (Core/Skin_EllesmereUI.lua, CollectOwn).
    frame.__pbPopupFloorHolder = holder

    local art = holder:CreateTexture(nil, "BACKGROUND", nil, -8)
    art:SetAllPoints(holder)
    frame.__pbPopupFloor = art

    -- Re-resolved every time the popup opens: by then a skin that arrived after
    -- the popup was built has run, and a profile switch has landed.
    if type(frame.HookScript) == "function" then
      frame:HookScript("OnShow", PaintPopupFloor)
    end
  end

  PaintPopupFloor(frame)
end

-- The list interior: the mail list container and the recipient manager's list.
function Theme.ApplyList(frame)
  PaintSurface(frame, "list", "list")
end

-- Every other card and popup: the detail view, the type-ahead popup, the
-- contact picker, the shared dropdown's list.
--
-- `__pbPopupAlways` is a caller's declaration that the card IS a popup no
-- matter what the strata comparison says. The dropdown list needs it: inside
-- the options panel -- itself at FULLSCREEN_DIALOG -- the list cannot outrank
-- its parent, so Floats() misses the one popup that opens over rows of text.
function Theme.ApplyCard(frame)
  PaintSurface(frame, "card", "card")
  if frame and (frame.__pbPopupAlways or Floats(frame)) then PinPopupOpacity(frame) end
end

-- The totals banner, and nothing else. A divider, not a panel; the skins treat
-- `band` differently, with no inset.
function Theme.ApplyBand(frame)
  PaintSurface(frame, "controls", "band")
end

-- An input is a card that wraps an edit box. Passing the inner box tags it too,
-- so the pair can never be half-tagged.
function Theme.StyleInput(frame, editBox)
  if not frame then return end
  Theme.ApplyCard(frame)
  frame.__postboxInputWrap = true
  if editBox then editBox.__postboxNoEditSkin = true end
end

-- Item slots get the card *border* and nothing else: no fill, no grain, no
-- panel tag. The previous build laid down the native slot art, shaded it, and
-- then applied a full-alpha card surface above both, so the art was dead
-- pixels; both skins zeroed that texture, which is why it was never seen.
function Theme.ApplySlot(slot)
  if not slot or type(slot.SetBackdrop) ~= "function" then return end

  if not slot.__pbSlotSurface then
    slot.__pbSlotSurface = true
    slot:SetBackdrop(SLOT_BACKDROP)
  end

  if type(slot.SetBackdropColor) == "function" then
    local fill = C.slotFill
    slot:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
  end
  if type(slot.SetBackdropBorderColor) == "function" then
    local edge = C.slotBorder
    slot:SetBackdropBorderColor(edge[1], edge[2], edge[3], edge[4])
  end
end

-- Kept because it is the name the previous build used, but routed through the
-- tagging entry points so it can no longer produce an untagged themed surface.
-- New code calls ApplyList / ApplyCard / ApplyBand directly. This overrides the
-- untagged re-export BindAddon installs.
function Theme.ApplyBackdropTheme(frame, variant)
  if variant == "list" then return Theme.ApplyList(frame) end
  if variant == "band" or variant == "controls" then return Theme.ApplyBand(frame) end
  return Theme.ApplyCard(frame)
end

-------------------------------------------------------------
-- 7. Control plates
--
-- Window tabs, the segments of a switch, and the recipient category tiles are
-- one control drawn three ways. This is that control.
--
-- WHY WE DRAW IT. Not built from PanelTabButtonTemplate: that template's
-- artwork is a Left/Middle/Right assembly whose Middle has a fixed XML width
-- and whose Right anchors to it, so only PanelTemplates_TabResize stretches it.
-- A bare SetWidth widens the clickable frame to ~250px while the art stays
-- ~115px and the centred label lands off the end of its own graphic. Both
-- host-UI skins destroy that art and draw their own, so the defect only ever
-- showed on a stock UI, where nobody was looking. A plate is correct at any
-- width and in any locale, keeps the selected tab clickable (Blizzard's helper
-- disables it, which is why the ElvUI skin has to re-enable it and re-centre
-- its shifted label), and leaves both skins with less to undo.
--
-- ONE RECIPE, THREE VARIANTS. One plate recipe for everything was nearly right
-- and wrong in one specific way: it fixed the HEIGHT as well as the look, and a
-- 22px window tab, a 22px switch segment and a 22px tile in a dense bar are not
-- the same control. The variants differ in exactly three things -- height,
-- whether they carry a selected underline, and which text role their caption
-- takes -- and share the fill/ring/bevel ladder, which is the part that has to
-- be identical for them to read as one family.
--
--   "tab"      a window tab. The heaviest: tallest, underlined when selected.
--   "segment"  one member of a segmented switch. Underlined when selected.
--   "tile"     a flat tile in a dense bar. Shortest, no underline -- five of
--              them side by side with underlines is a fence, not a control --
--              and it supports a `flagged` state for a tile whose glyph alone
--              is too small to carry a fact (the favourites star).
--
-- THE SKIN CONTRACT, unchanged. `Text` is the button's registered font string
-- (SetFontString), so SetText/GetText drive it and both skins find it to mirror.
-- `__activeBg` is the selected wash under the name both skins reach for.
-- `isSelected` is the state they read. A skin may install
-- `__setSelectedOverride`, after which it owns the entire visual: the first
-- call through SetPlateSelected retires our art for good, so the two can never
-- draw on top of each other. Every texture the plate owns -- including the
-- bevel added here -- goes into `__pbPlateArt`, which is the single list
-- HidePlateArt walks, so a new decoration can never be one a skin cannot
-- retire.
-------------------------------------------------------------

local function PaintTexture(texture, color)
  if not texture then return end
  texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
end

local PLATE_VARIANTS = {
  tab     = { height = M.tabHeight,     role = "tab",     underline = true },
  segment = { height = M.segmentHeight, role = "segment", underline = true },
  tile    = { height = M.tileHeight,    role = "segment", underline = false },
}

Theme.PlateVariants = PLATE_VARIANTS

-- Repaints a plate from its own state. A no-op once a skin has taken it over
-- (HidePlateArt drops __pbPlateArt), so hover scripts still attached to a
-- skinned plate can never repaint underneath it.
--
-- Every accent here comes from Theme.GetAccentTone or from an accent-named
-- token through Theme.FillColor -- never from the palette constant -- so one
-- control cannot end up on the brand gold while its neighbour follows the host
-- UI's accent.
local function PaintPlate(plate)
  if not plate or not plate.__pbPlateArt then return end

  local selected = plate.isSelected and true or false
  local hovered  = plate.__pbHover and true or false
  local flagged  = plate.__pbFlagged and true or false

  local fill = C.plateIdle
  if selected then fill = C.plateSelected
  elseif hovered then fill = C.plateHover
  elseif flagged then fill = C.plateFlagged end
  PaintTexture(plate._fill, fill)

  -- The ring: one white at three alphas, plus the single exception.
  --
  -- Selection is signalled by WEIGHT (0.20 -> 0.35 -> 0.55) and not by hue,
  -- because the ring is on screen four to eight times at once and a hue on it
  -- is a hue on the whole window. The exception is the favourites flag, which
  -- is the one ring here that states a fact rather than a state -- and being
  -- the only coloured ring is precisely what lets it be noticed.
  --
  -- Selected is tested first, so an open tile that also has favourites shows
  -- the selected ring: "this is the filter the list is under" is the more
  -- urgent of the two, and the count beside the star says the rest.
  if selected then
    PaintTexture(plate._edge, C.plateEdgeSelected)
  elseif flagged then
    -- Through FillColor, so the flag ring follows a host UI's accent.
    Theme.FillColor(plate._edge, "accentEdge")
  elseif hovered then
    PaintTexture(plate._edge, C.plateEdgeHover)
  else
    PaintTexture(plate._edge, C.plateEdge)
  end

  local activeBg = plate.__activeBg
  if activeBg then
    if selected then
      local r, g, b = Theme.GetAccentTone("base")
      activeBg:SetColorTexture(r, g, b, C.accentWash[4])
    end
    activeBg:SetShown(selected)
  end

  local underline = plate._accent
  if underline then
    if selected then
      local r, g, b = Theme.GetAccentTone("base")
      underline:SetColorTexture(r, g, b, 1)
    end
    underline:SetShown(selected)
  end

  if plate.Text then
    Theme.SetColor(plate.Text, selected and "accentBright" or "plateCaption")
  end
end

Theme.RepaintPlate = PaintPlate

local function HidePlateArt(plate)
  local art = plate.__pbPlateArt
  if not art then return end
  plate.__pbPlateArt = nil
  for i = 1, #art do art[i]:SetAlpha(0) end
end

-- Builds one plate. `variant` is a key of PLATE_VARIANTS; `name` is optional and
-- is only wanted where something has to find the frame globally (the window
-- tabs, which the skins address by name).
function Theme.CreatePlate(parent, variant, name)
  local spec = PLATE_VARIANTS[variant] or PLATE_VARIANTS.segment

  local plate = CreateFrame("Button", name, parent)
  plate:SetHeight(spec.height)
  plate.isSelected = false

  local edge = plate:CreateTexture(nil, "BACKGROUND", nil, -1)
  edge:SetAllPoints()

  local fill = plate:CreateTexture(nil, "BACKGROUND", nil, 0)
  fill:SetPoint("TOPLEFT", plate, "TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -1, 1)

  -- The selected-state wash. Called __activeBg because that is the name both
  -- skins reach for when they hide our selection visual.
  local activeBg = plate:CreateTexture(nil, "ARTWORK", nil, -1)
  activeBg:SetPoint("TOPLEFT", plate, "TOPLEFT", 1, -1)
  activeBg:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -1, 1)
  activeBg:Hide()

  -- The lit top edge. One texture, one tenth of an alpha, and it is the whole
  -- difference between a rectangle of colour and something that looks pressable.
  local bevel = plate:CreateTexture(nil, "ARTWORK", nil, 1)
  bevel:SetHeight(1)
  bevel:SetPoint("TOPLEFT", plate, "TOPLEFT", 1, -1)
  bevel:SetPoint("TOPRIGHT", plate, "TOPRIGHT", -1, -1)
  PaintTexture(bevel, C.plateBevel)

  local art = { edge, fill, activeBg, bevel }

  local underline
  if spec.underline then
    underline = plate:CreateTexture(nil, "ARTWORK", nil, 0)
    underline:SetHeight(2)
    underline:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", 1, 1)
    underline:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -1, 1)
    underline:Hide()
    art[#art + 1] = underline
  end

  local highlight = plate:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetPoint("TOPLEFT", plate, "TOPLEFT", 1, -1)
  highlight:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -1, 1)
  PaintTexture(highlight, C.plateHighlight)
  art[#art + 1] = highlight

  -- Centred and deliberately unconstrained: a font string with no width can
  -- never clip, so a long deDE/ruRU label is safe however narrow the window
  -- gets. SetFontString registers it as the button's own label, which is what
  -- SetText/GetText drive and what both skins look for when they mirror it.
  local role = spec.role
  local label = plate:CreateFontString(nil, "OVERLAY", (TEXT_ROLES[role] or TEXT_ROLES.segment).font)
  label:SetPoint("CENTER", plate, "CENTER", 0, 0)
  label:SetWordWrap(false)
  plate:SetFontString(label)
  plate.Text = label
  plate.__pbTextRole = role

  plate._edge, plate._fill, plate._accent = edge, fill, underline
  -- The same texture under the name the hand-rolled category bars gave it, so
  -- adopting this factory is a deletion rather than a rewrite.
  plate._bg = fill
  plate._bevel = bevel
  plate.__activeBg = activeBg
  plate.__pbPlateArt = art

  -- An owner that needs its own OnEnter/OnLeave -- a tooltip, usually -- must
  -- HookScript rather than SetScript, or call Theme.SetPlateHover from its own
  -- handler. SetScript replaces these and the plate then never repaints on
  -- hover again, silently.
  plate:SetScript("OnEnter", function(self) Theme.SetPlateHover(self, true) end)
  plate:SetScript("OnLeave", function(self) Theme.SetPlateHover(self, false) end)

  PaintPlate(plate)
  return plate
end

function Theme.SetPlateHover(plate, hovered)
  if not plate then return end
  plate.__pbHover = hovered and true or false
  PaintPlate(plate)
end

-- "This plate carries something its glyph is too small to say on its own" --
-- the favourites star with favourites behind it. Selection still outranks it.
function Theme.SetPlateFlagged(plate, flagged)
  if not plate then return end
  plate.__pbFlagged = flagged and true or false
  PaintPlate(plate)
end

function Theme.SetPlateSelected(plate, selected)
  if not plate then return end
  selected = selected and true or false
  plate.isSelected = selected

  -- A host-UI skin can install its own selection visual. When it has, it owns
  -- the whole look: retire our plate art and run nothing else here, or the two
  -- fight over the control on every switch.
  local override = plate.__setSelectedOverride
  if override then
    HidePlateArt(plate)
    override(plate, selected)
    return
  end

  PaintPlate(plate)
end

-- Re-applies the caption's font role and repaints. Call after a theme or locale
-- change; the plate remembers which role it was built with.
function Theme.StylePlate(plate)
  if not plate or not plate.Text then return end
  Theme.ApplyTextRole(plate.Text, plate.__pbTextRole or "segment")
  PaintPlate(plate)
end

-- Window tabs. The names are kept because Core/MailboxUI.lua and both skin
-- files call them; each is the plate entry point above at the "tab" variant.
function Theme.CreateTab(name, parent)
  return Theme.CreatePlate(parent, "tab", name)
end

Theme.StyleTab = Theme.StylePlate
Theme.SetTabSelected = Theme.SetPlateSelected

-- Dynamic tab captions (the Mail tab's inbox counts) go through here, never
-- through a bare Button:SetText. SetText re-applies the button's font-object
-- colour to its fontstring, which undoes what every skin backend did to that
-- label: EllesmereUI's engine and the compat shim hide it (alpha-0) behind a
-- mirror of their own -- SetText resurrects it UNDER the mirror and both
-- render -- and ElvUI recolours it in place -- SetText snaps it back to the
-- role colour. Re-running the selection pass hands the label straight back
-- to whoever owns it: the skin override re-skins (and the EllesmereUI
-- override re-hides), the house path repaints.
function Theme.SetTabText(tab, text)
  if not tab then return end
  if tab:GetText() == text then return end
  tab:SetText(text)
  Theme.SetPlateSelected(tab, tab.isSelected)
end

function Theme.ApplyTabBarBg(tabBar)
  if SharedTheme and SharedTheme.ApplyTabBarBackground then
    SharedTheme.ApplyTabBarBackground(tabBar)
  end
end

-------------------------------------------------------------
-- 8. Mail rows
--
-- Texture-based via the foundation layer's RowStyling, not backdrop-based.
--
-- `position` is the row's DISPLAYED position, not its inbox index: the list is
-- filtered by view mode, so striping by inbox index shows three identically
-- shaded rows in a row in the read view.
--
-- The state fields are still written because the hover handlers repaint through
-- RowStyling.Apply(row) -- the state form -- and would otherwise have nothing
-- to read. The paint itself goes through the direct form, which is what makes
-- this cheap enough to call on every re-bind of a pooled row.
-------------------------------------------------------------
function Theme.StyleMailRow(row, position, hovered)
  if not row then return end

  if not row._bg then
    row._bg = row:CreateTexture(nil, "BACKGROUND")
    row._bg:SetAllPoints()
  end
  row.bg = row._bg

  row._rowIndex = tonumber(position) or 0
  row._hovered = hovered and true or false

  if RowStyling and RowStyling.Apply then
    RowStyling.Apply(row, row._rowIndex, row._hovered)
  end
end
