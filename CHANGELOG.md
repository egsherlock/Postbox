# Changelog

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
