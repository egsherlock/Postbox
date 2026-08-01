# Changelog

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
