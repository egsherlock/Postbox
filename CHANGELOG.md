# Changelog

## 1.11.1

- Manage Recipients is a composed portrait button now: title, a ghosted
  letter-bundle watermark, and the live count beneath - and the same
  doorway sits at the right edge of the Send tab's recipient field, so the
  manager is one click from where recipients are typed.
- The preview stage matches the toggle-and-switcher column's full height,
  and the EllesmereUI paragraph shrinks to one quiet line with the full
  explanation in its tooltip.

## 1.11.0

- The minimap block is a 2x2 toggle grid now - Glow and Shadow on top,
  Accent and new **Pulse** (the glow's slow breathe, on by default)
  beneath - beside the preview stage, which sits on a neutral terrain-tone
  ground so the shadow is actually visible. All four preview live.
- Manage recipients is a tall portrait button filling the space beside the
  General checkboxes - more obvious, and one row shorter.
- The bug-report window has a proper little x to close it.

## 1.10.1

- The minimap section is a compact block now: a larger preview stage with
  Accent / Glow / Shadow as one row of small toggles beside it and the icon
  switcher underneath, aligned to the stage - three rows shorter overall.
- "Accent colour" is just "Accent", and its tooltip tells the truth: it
  colours the glow and any tintable icon style, not "the envelope".

## 1.10.0

- **Run memory.** The warning triangles and the Stuck count now survive
  closing and reopening the mailbox for the rest of the session, and the
  last run that ended badly is remembered across sessions: the next mailbox
  visit opens with "Last visit: N mails could not be taken — the game
  said: ..." in the status line. A clean run, or an inbox that resolved
  itself, erases the note. One tiny saved record per character; no
  background work.
- The icon picker grew a proper showcase: the current icon at readable size
  on a dark stage, wearing the live accent, glow (pulse included) and the
  new shadow, updating as you toggle.
- The bug-report window is fully opaque now, and its single setup line grew
  into a copyable diagnostic report (version, client, UI-pack handshake,
  minimap settings, last bad run). /postbox debug opens it from anywhere.

## 1.9.1

- Author corrected to egsherlock, matching GitHub and CurseForge.

## 1.9.0

- The icon picker's open list now shows every icon beside its name - the
  way to browse the collection without pending mail - and the preview
  swatch beside the dropdown survives host-UI skinning (it was being
  faded by EllesmereUI's repaint, as were the status band's green light
  and wash).
- New **Shadow** option: a soft dark shadow behind the icon, alongside
  Glow, in both own-icon and EllesmereUI-styled modes.
- The bug-report popup is a proper little window now - above the panel,
  movable, opaque, with the address focused and pre-selected so Ctrl+C is
  the only keystroke needed. It previously rendered interleaved with the
  panel's own controls.
- Version footer no longer reads vv1.8.0 - the release tag already
  carries the v.

## 1.8.0

- The addon-list icon is now the clean London Postbox.
- The minimap icon picker row is now the picker itself: a live preview
  swatch of the current choice beside a full-width dropdown, instead of a
  label stranded across the card from a small button.
- The status band grew up: centred text with a green status light and a
  subtle green wash (your UI pack's settings are wired in), the addon
  version in the corner, and clicking the band opens a tiny bug-report
  popup with the report address and a copyable one-line setup summary.

## 1.7.0

- Eight "clean" restyles of the painted set, each sitting directly beneath
  its original in the icon picker; the pillar postbox is now properly named
  **London Postbox**, and the two flat glyphs are **Envelope minimal** and
  **Badge minimal**. The red, white and iron mailboxes are retired.
- The icon picker now scrolls: long lists cap at twelve rows with a minimal
  hairline scrollbar, open centred on the current selection, and the list is
  no longer see-through (a popup-detection gap left it skipping the opacity
  floor every other popup gets).
- The minimap master checkbox now sits on the section heading line, right-
  aligned above the card it enables, and the style footer is a proper status
  band: "Options synced with EllesmereUI" (or ElvUI, or Postbox's own
  style).

## 1.6.2

- The pillar postbox is now the addon-list icon; flip the TOC's IconTexture
  back to Media\icon.png to restore the mailbox.

## 1.6.1

- The nine icon styles from the third sheet re-cut from a cleaner source
  with true transparency - same styles, better edges.

## 1.6.0

- Fifteen more hand-painted minimap icon styles: open letter, scroll,
  mailboxes in red, white and iron, mail bag, satchel, quill and ink,
  stamped and weathered envelopes, letter bundle, pillar postbox, and
  stone, wooden and golden crests. Letter stack and Plate are retired
  (selections fall back to the painted Letter, the new default).
- The minimap section's master checkbox now sits above its settings card,
  and an unchecked box desaturates and locks the card — the controls
  visibly belong to the checkbox.

## 1.5.0

- Five hand-painted minimap icon styles in the stock-Blizzard spirit:
  **Letter**, **Sealed letter**, **Parcel**, **Wax seal** and **Letter
  stack** — bold, warm, readable at minimap size. The flat generated glyphs
  and the stock Blizzard envelope remain available.
- The glow is back to the soft disc from 1.4.0 — the halo ring read as an
  explosion in game. The painted icons' bold borders sit crisply on top of
  it.
- The options panel now groups each section — General, Minimap, Appearance —
  on its own card surface, the same panel surface the main window uses, so
  host-UI skins paint it natively.

## 1.4.1

- The glow is now a halo — a soft ring around the icon instead of a disc
  behind it, so a tinted glyph no longer melts into a same-coloured blob and
  the icon stays crisp.
- Accent colour now defaults to off for the minimap icon; the glow still
  follows the accent either way.

## 1.4.0

- Three new minimap icon styles drawn for small sizes — **Envelope** (bold
  classic), **Plate** (filled rounded tile with an envelope knockout) and
  **Badge** (envelope with a notification dot) — all accent-tintable. The
  muddy "Minimal" and "Mailbox" styles are gone; anyone who had them selected
  moves to Envelope automatically.
- The options panel got a tidy-up: sections ruled off under General, Minimap
  and Appearance headings, and a status line at the bottom showing which
  style is painting Postbox right now (EllesmereUI, ElvUI, or Postbox's own).

## 1.3.0

- With EllesmereUI's minimap active, Postbox no longer draws a second mail
  icon — it restyles EllesmereUI's own mail icon in place with your chosen
  icon style, accent tint and glow, while EllesmereUI keeps controlling its
  visibility, position and size. One icon, styled yours, positioned theirs.
  Everything is restored exactly when the option is switched off, and if a
  future EllesmereUI changes internally the styling simply stands down.
  Without EllesmereUI's minimap, Postbox's own icon works as before.

## 1.2.0

- The minimap mail icon now sits **inside** the map edge with a position
  dropdown — top right by default, any corner, or Custom via shift-drag.
- Suppressing the default indicator no longer generates Show/Hide traffic,
  which was making EllesmereUI relayout its minimap elements twice per mail
  event (the mouseover-hidden button bar flicker). Side benefit: EllesmereUI's
  own mail icon — which its settings cannot turn off and which mirrors those
  same events — no longer pops up alongside Postbox's for mail arriving
  mid-session. Mail already waiting when EllesmereUI runs a layout pass (at
  login or on its settings changes) can still surface its icon until
  collected; that one is only fixable in EllesmereUI itself.

## 1.1.0

- **Minimap mail icon** (off by default; options panel or `/postbox minimap`) —
  replaces the default new-mail indicator with Postbox's own icon on the minimap
  edge. Four icon styles, four sizes, optional accent-colour tint (follows your
  EllesmereUI accent when that skin is active) and an optional soft glow with a
  slow pulse while mail waits. Shift-drag the icon anywhere on the rim — round
  and square minimaps both handled. Plays fair with the host UI: the default
  indicator is suppressed cleanly and restored intact on disable, the crafting
  order indicator is untouched, and the button is invisible to EllesmereUI's and
  ElvUI's minimap button collectors.

## 1.0.0

Initial public release.

- **Collect** — the whole inbox on three tabs (Collect / Done / All), with one-click
  category sweeps and bulk collection that is safe by design: every server command
  is acknowledged before the next is sent, refused items are skipped rather than
  ending the run, and a run that cannot finish says so. Preview any mail without
  collecting it, hover attachments for real item tooltips, and mail the server
  refuses to hand over is marked with the game's own reason.
- **Send** — inline name completion (Tab accepts, Tab cycles), a recipient system
  whose categories mean what they say (Recent, Alts, Friends, Guild), favourites,
  and send guidance that tells you what will happen before you send. The window
  grows with your message as you type.
- **Recipient manager** (`/postbox recipients`) — curate every name Postbox can
  offer: search, sort, favourite, hide, annotate.
- **Optional EllesmereUI and ElvUI skins** — Postbox follows your own host-UI
  settings, live. With neither installed it uses its own theme.
- Five languages: English, Français, Deutsch, Español, Русский. Contributions
  welcome.
