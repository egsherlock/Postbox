# Changelog

## 1.28.0

- **The minimap tooltip is Postbox's own now.** It used to open with the
  game's "Unread mail from:" and three bare names, then repeat itself in
  better words underneath. It now describes the mailbox once: what has
  arrived since you last looked, what is waiting to be collected broken
  down by sender, and how many of those the game refused to hand over.
- **A mail you opened but could not empty finally counts.** The breakdown
  asked which mail was *unread*, so the stuck Postmaster mail — opened,
  refused, still holding your item — was silently missing while five
  auction mails were listed. It now asks which mail still *holds*
  something, which is the question you were actually asking, and says
  "1 could not be collected" underneath when the game refused one.
- **The dropdown selection marker is a dot.** It was a tall bar down the
  row's left edge, a hairline from the list's own border, so the two read as
  one thick line — and every caption now starts at the same place whether
  or not it is the chosen one.
- **Borders land on real pixels.** A one-pixel edge at a fractional UI
  scale gets rounded per side by the client, which is why some edges looked
  a shade heavier than others. Every hairline now snaps to a whole physical
  pixel, so the flat look is even everywhere.

## 1.27.0

- **Postbox Modern got its edges right.** Those extra dark pixels above
  fields, under buttons and along panel edges were the flat look's own
  hairline: a pure-black border on near-black surfaces, which stacked into
  a two- or three-pixel smear wherever two elements sat close. The hairline
  is now a faint light line instead — it separates by brightness, the way
  flat interfaces actually do, and two of them side by side read as one.
- **Modern has a title bar again**, a shade above the window behind the
  title, the cog and the close button, closed off with a hairline — the
  same distinction every other Postbox look has.
- **Modern skins the scroll bars too**: the art goes and the thumb becomes a
  thin bright bar, in the mail list and the recipient window alike. (Scroll
  bars are ordinary interface frames — restyling them carries no taint and
  no combat consequence, which is why the host-UI skins have always done
  the same.)
- **The minimap icon's tooltip now breaks your mailbox down by sender** —
  "Auction House  x5", "Postmaster  x1" — instead of the game's bare list of
  three names. It re-reads every time you hover, so it follows new arrivals.
- **New: optional alerts when mail arrives.** A sound (the game's own mail
  chime) and a flash (the icon beats a few times, then settles). Both off by
  default, both in the Minimap section. The flash is a pulse in size rather
  than another glow, so it composes with whatever glow, shadow and accent
  the icon already wears instead of fighting them.
- The Mail tab's caption now defaults to the quiet dot — the smallest thing
  that answers "is there anything to collect" from the Send tab.

## 1.26.0

- **The options panel says one thing in one place.** The footer used to
  announce which look was painting the addon — in the wrong place, and
  wrongly: it read "Postbox's own style" even when the Blizzard style was
  the deliberate choice. That sentence now lives in a **Style** section
  which is always present: with EllesmereUI or ElvUI it names the skin
  driving the window, and without one it offers the choice. The footer is
  what a footer is for: the version, and a **Report a bug** label that
  finally says what clicking the band has always done.
- **The All view can be switched off.** Collect and Done are the two halves
  of your inbox; All is their union, and some players want the row shorter.
  A new General option keeps it or drops it, and the view falls back to
  Collect if you hide the one you were on.
- **The mailbox memory's new-mail badge is a badge now** — an accent pill
  with a dot rather than one more line of coloured text beside a list of
  mails. Hovering it gives a proper summary: what has arrived since you
  looked, then what was already unread, grouped by sender —
  "Auction House  x10" instead of ten rows to count.
- **Postbox Modern draws its own close button**: a crisp accent-lit X in
  place of the stock gold-ringed one, which was the last piece of Blizzard
  chrome surviving the flat look.
- The Mail tab no longer carries the standing note that C.O.D. mail is
  never collected automatically. It never was, the confirmation dialog says
  so at the only moment it matters, and the top row is quieter without it.

## 1.25.0

- **A window style of your own: "Postbox Modern".** Players on the plain
  Blizzard UI get a Style choice in options: **Blizzard** (the built-in
  warm-stone native look, still the default) or **Postbox Modern** — flat
  near-black surfaces, hairline borders, and the accent doing all the
  talking. It rides the exact same skinning pipeline the EllesmereUI and
  ElvUI integrations use, so every window gets it consistently — and under
  EllesmereUI or ElvUI the choice doesn't appear at all: those skins always
  win, exactly as before. Takes effect after a /reload.
- **The minimap icon's tooltip now answers the real question**: it leads
  with what your mailbox held — "Last seen 2 h ago — 12 mails" — before the
  gesture lines, so you know whether the trip is worth it without a click.
- **German, Spanish and Russian are fully translated.** Around ninety
  strings per language — the contact picker, the recipient manager's newer
  screens, and every option added since — no longer fall back to English.

## 1.24.7

- The mailbox memory window closes itself when you open a real mailbox —
  the actual inbox supersedes the memory of it.

## 1.24.6

- **Found a structural way the "+ new mail" badge could never show**: if a
  mailbox visit ends without the close signal reaching the memory module,
  the window keeps reading that visit's live capture — which shows the
  right mails, while every arrival mark lands on the saved record the
  window is no longer looking at. Content correct, badge impossible. The
  module now listens to both of the game's close signals like the main
  window does, settles a missed close by itself the next time the window
  opens, and carries any arrival marks across.
- `/postbox debug` now also states whether a live capture is stranded and
  whether every event the memory relies on actually registered on this
  client — the two remaining ways this feature could fail invisibly.

## 1.24.5

- **Buying at the auction house now lights the "+ new mail" badge
  directly.** The game sends no new-mail signal at all while your mail flag
  is already up — an auction purchase on top of existing unread mail, the
  most common arrival there is, was completely silent even to Blizzard's
  own UI. So Postbox stops waiting to hear about the mail and reacts to the
  purchase itself: the game announces your completed buyout, and a
  completed buyout IS mail on its way. The badge's tooltip credits the
  Auction House.
- The Manage Recipients button's fill is the card's own tone one step
  lighter — a neutral near-black instead of the warm brown, which read as a
  different material rather than a subtle lift.

## 1.24.4

- The mailbox memory's arrival detectors now arm themselves on update: a
  snapshot saved by an older version gets its baseline at login or first
  look instead of needing one more mailbox visit before the "+ new mail"
  badge could work at all.

## 1.24.3

- **The "+ new mail" badge detects arrivals three independent ways** —
  because one way kept failing quietly. It still uses the game's arrival
  event when that fires; it also notices the new-mail flag FLIPPING (off
  when you left the mailbox, on now — which can only mean an arrival); and
  it now remembers who your latest unread senders were when the box closed
  and spots that line changing, which even catches mail that arrived while
  you were logged out. A mailbox visit resets all three.
- **The Manage Recipients button was transparent all along** — the plain
  UI's button frame has no background support, so every earlier colour fix
  was applied to a background that did not exist and you were seeing the
  dark card through the button. It gets a real backdrop now, and the warm
  raised tone finally shows.
- `/postbox debug` now also reports whether the game's pending-mail event
  fired at all and what the badge's three detectors each currently say.

## 1.24.2

- **The "+ new mail" badge is honest at last.** It turns out the game's
  new-mail flag stays lit the whole time UNREAD mail sits in your box — it
  means "you have unread mail", not "something just arrived" — which is why
  the badge lit permanently for anyone with an uncollected auction mail.
  The badge now marks only a witnessed arrival: the game's pending-mail
  event, filtered so the login pulse and mailbox-close churn never count.
  One honest limit comes with that: mail that arrives while you are logged
  out cannot be told apart from mail you already knew about, so the badge
  only ever claims arrivals it actually saw this session.
- **The Manage Recipients portrait actually reads as a button now** — the
  previous lift was painted underneath the card's opaque surface grain, so
  it never showed. The grain steps aside and the warm raised tone shows.
- The sealed letters are one family now: **Sealed letter 1–4** (formerly
  Sealed letter, Sealed envelope, its "2", and Weathered letter), and the
  two Letter bundles sit directly after the letters in the icon list.

## 1.24.1

- **The "+ new mail" badge no longer depends on catching the moment.** It
  now also reads the game's own new-mail flag every time the memory window
  opens — away from a mailbox that flag can only mean "arrived since your
  last visit", which is exactly what the badge claims — so a missed event
  can no longer hide it. `/postbox debug` also reports the memory's whole
  state now, so if it ever misbehaves again one paste shows why.
- The Manage Recipients portrait wears a slightly lifted tone on the plain
  UI instead of pure black, so it reads as a button rather than a hole.
- "Blizzard's own spot" is now "Blizzard's default" in the position list.
- **Minimap icon names cleaned up**: variants that said "clean" are now
  simply "2" ("Letter 2", "London Postbox 2", "Golden crest 2"), and the
  letter family is named consistently — "Letter minimal", "Sealed envelope",
  "Weathered letter".

## 1.24.0

- **Right-click-to-attach is simply how Postbox works now** — the option is
  gone. With a mail window open, clicking an attachable item flips to Send
  with it attached, the same way Blizzard's own Send tab has always behaved;
  your bags are untouched the moment the mailbox closes.
- **The minimap icon's tooltip earns its keep**: one line per gesture with
  the gesture in gold — Click, Right-click, Shift-drag, Alt-click — and each
  line only appears while it is true: the mailbox-memory line disappears
  when that feature is off, and the move line disappears while the position
  is locked.
- **Mailbox memory opens at six rows** (its minimum — the grip only grows
  it), and the "+ new mail" badge now appears the moment mail lands, even
  while the window is open.
- The position list says "Minimap" instead of "Map edge" — it never meant
  the world map.
- **The Manage Recipients button looks right on the plain UI**: the stock
  button art is a thin strip that smeared into pixel blocks when stretched
  to portrait height (host skins repainted over it, the plain UI showed it
  raw). Without a skin it now wears a flat card surface instead. And the
  window's options cog sits level with the title on the plain UI.

## 1.23.0

- **Turning the minimap icon on now looks good immediately**: fresh setups
  get the Letter icon at the map's top right with the glow, pulse and shadow
  already on — switching the feature on is the opt-in, and every piece still
  has its own checkbox. (Existing setups keep whatever they chose.)
- **The position list now says where each choice anchors**: "Blizzard's own
  spot", "Map edge - top right", "Map edge - custom", "Anywhere on screen" —
  attached-to-the-map versus free is visible in the list itself.
- **Alt-click the minimap icon to lock or unlock its position**, and the
  icon's tooltip always says which state it is in — a locked icon that
  silently ignored shift-drag used to read as broken. The options checkbox
  and the alt-click stay in step.
- **The accent tooltip tells the truth on every UI**: it tints with whatever
  accent Postbox is currently using — your host skin's when one is active,
  Postbox's own gold otherwise. It previously only mentioned EllesmereUI.
- **The mailbox memory now separates "seen" from "since".** The list is what
  your mailbox held when you looked; a small accent "+ new mail" badge
  appears only when something has arrived AFTER that snapshot, and hovering
  it names the senders the game offers. No more wondering whether "new mail
  is waiting" was talking about the rows you were already looking at.

## 1.22.0

- **Minimap icon placement is one honest list now.** The position dropdown
  carries every mode: **Blizzard default** (new — the icon sits exactly
  where the stock mail indicator does, so you can restyle it without moving
  anything; this is now the default for fresh installs), the four corners,
  **Custom** (shift-drag along the map edge) and **Free** (shift-drag
  anywhere on screen). The separate detach checkbox is gone — it and the
  dropdown kept contradicting each other. Shift-dragging updates the
  dropdown itself: a drag in any edge mode becomes Custom, a drag in Free
  stays Free, and the open options panel reflects it immediately.
- Left-clicking the minimap icon while your mailbox is already open now says
  so in chat instead of silently doing nothing.

## 1.21.0

- **The mailbox memory window grew manners.** It opens beside the minimap
  instead of on top of it, shows eight rows by default and scrolls the rest,
  and resizes vertically with the usual corner grip — between four rows and
  however many it holds; the width stays put. Hovering a mail shows the real
  item tooltip where the game had one recorded (read mail), the full subject
  otherwise. "New mail is waiting" now sits apart from the "last seen" line
  so the old list and the new arrival can't read as one sentence. And the
  whole feature has its own switch in the minimap card, on by default —
  switched off, nothing is recorded and the click does nothing.
- **Minimap icon placement is now three plain controls instead of one
  overloaded list.** The position dropdown keeps the corners and Custom; a
  "Detach from minimap" checkbox frees the icon to sit anywhere on screen
  (picking a position re-attaches it); and a new "Lock position" checkbox
  stops shift-drag entirely for anyone tired of nudging their icon by
  accident. The controls also update immediately after a drag or a reset —
  no more dropdown claiming a mode the icon left a moment ago.
- **The attach option finally says what it does**: it is called "Right-click
  attaches items" now, and its tooltip is one plain sentence instead of a
  riddle. Still on by default; bags are only ever affected while the mailbox
  window is open.

## 1.20.0

- **Left-click the minimap icon to see what your mailbox held — from
  anywhere.** Postbox now remembers the inbox as you last saw it and shows
  it in a small window: each mail's icon, sender, subject, its gold or
  C.O.D. or attachment count, and how long it had left. The window is
  honest about being a memory: it leads with "Last seen 2 h ago", tells you
  when new mail has arrived since, and greys mails whose timer has run out
  in the meantime. At an actual mailbox the click does nothing — the real
  thing is on screen. The snapshot rides the inbox reads Postbox already
  does (the game shows at most ~50 mails at a time, so this is light even
  for the fullest mailbox) and costs one small save per mailbox visit;
  nothing at all runs while you play.

## 1.19.1

- **"Attach from the Mail tab" actually works now.** The game's own
  mailbox-open sequence was quietly switching the attach mode back off a
  moment after Postbox armed it — so a right-click on a bag item while
  reading mail USED the item (drank the potion, tried to equip the armour)
  instead of attaching it. The flag is now guarded for the whole mail
  session: whatever switches it off while Postbox needs it on, it is
  re-armed on the spot. Right-clicking a bag item on the Mail tab flips to
  Send with the item attached, exactly as on the Send tab itself.
- **The 1.18.1 replacement surfaces are reverted.** The self-made stone tile
  matched neither real Blizzard rock (pristine installs looked worse) nor a
  UI pack's replacement art (pack installs got a third look that matched
  nothing). Postbox draws Blizzard's own surface and border art again, so on
  a pack-textured install it reads as part of that UI — the same way every
  Blizzard window does — and on a clean install it looks properly Blizzard
  again. The one keeper: plain white fills stay Postbox-owned, which is
  invisible and makes them override-proof.

## 1.19.0

- **The minimap icon can now leave the minimap edge.** A new "Detached"
  choice in the position dropdown lets shift-drag place the icon anywhere on
  screen — beside the map, under the clock, wherever — instead of only along
  the rim. It still follows the minimap through moves and scale changes,
  switching modes never teleports it, and it can never be lost off-screen.
  The corner presets and rim drag work exactly as before.
- **Opening the options now takes a right-click on the minimap icon.** A
  plain left-click no longer flings the settings window at you — the icon is
  a mail indicator first. The tooltip hint says so.

## 1.18.1

- **Postbox now looks right even when a UI pack has replaced the game's own
  textures.** Packs like AtrocityUI and NaowhUI ship files that silently
  replace standard Blizzard art for the whole interface — no addon involved —
  and Postbox's stone surface and panel backgrounds were built from two of
  the files they replace, which hollowed the window out into a dark
  transparent shell. Every structural fill, surface and border now comes
  from Postbox's own texture files, which nothing can override; standard
  controls (checkboxes, close buttons, glyphs) deliberately keep following
  whatever your base UI looks like.
- **Previewing a C.O.D. mail can no longer pay it.** Clicking an attachment
  inside the mail preview fired the take directly, and the first take from a
  C.O.D. mail pays the full amount — with no dialog. That click now gets the
  same confirmation as the Collect button, and the payment rule is enforced
  in one place for every path: nothing pays a C.O.D. except the single
  confirmed action you just approved.
- **Paying and deleting now leave a receipt in chat.** "C.O.D. paid: 12g 50s"
  after a confirmed payment actually goes through, and "Deleted: 8 mails"
  after the bulk sweep — so an irreversible action is never silent.
- Postbox's grey-out of unmailable bag items now restores the exact icon
  tint another addon may have applied, instead of resetting it to white.

## 1.18.0

- **Right-click an item in your bags while reading mail and the window flips
  to Send with it attached** — the same native attach the Send tab has always
  had, now armed across the whole mail session. The game client itself does
  the attaching (no bag hooks, nothing protected touched, works in combat and
  with replacement bag addons); Postbox just notices the attachment land and
  follows it to the Send tab. The flip side: while the mailbox is open, bag
  items answer to the mail — an unmailable one raises the game's own "can't
  be mailed" error instead of being used or opened, exactly as on the Send
  tab. A new option, "Attach from the Mail tab" (on by default), turns the
  whole thing off for players who use or open items from their bags while
  standing at the mailbox.
- **Every confirmation dialog now re-checks its mail before acting.** The
  dialogs are not modal: while one waits, collecting another mail (or new
  mail arriving) renumbers the whole inbox, and the "delete all read mail"
  sweep, the partial-run confirmation and the C.O.D. prompt all acted on the
  numbers they had captured when they opened. Each one now verifies, at the
  moment you accept — and the delete sweep again before every single delete —
  that each number still names the mail it described, and quietly skips any
  that moved. A shifted mail costs one more click; the wrong delete cost the
  mail.
- **Bulk collection can no longer pay a C.O.D. under any circumstances.**
  It was always designed never to touch C.O.D. mail, but that promise was
  only kept when the queue was built; it is now also enforced at the moment
  each mail is actually collected, so an inbox that renumbers mid-run cannot
  slip a C.O.D. mail under a queued number. Only the single-mail path — the
  one that just showed you the amount and asked — can ever pay.
- The recipient, subject and message fields now cap their length at what the
  server actually accepts (64, 64 and 500 letters), so an oversized paste is
  truncated up front instead of failing the send with a generic error.
- A remaining-quantity rewrite in mail subjects ("Auction successful: Ore
  (200)") now only touches a count at the END of the subject, so a
  player-written subject like "Ore (20) and bars (40)" is left alone.

## 1.17.2

- **Walking away mid-take no longer paints a phantom "stuck" marker.** The
  server refuses everything from out of range, and the client's cached
  headers keep reading "still full" for a beat after you leave - so the
  in-flight mail (and, via the shared fingerprint, every identical auction
  sibling) could be recorded as refused when a retry would take it
  instantly. Both refusal-recording paths now confirm the mailbox is still
  open before believing an unchanged mail. An already-recorded phantom
  clears itself the moment the mail is successfully collected.

## 1.17.1

- The walk-away note from 1.17.0 is gone again: reopening after leaving a
  run mid-sweep shows no special greeting. The leftovers are ordinary
  uncollected mail the segment counts already describe, so the note said
  nothing new - "Remaining" belongs to the live run counter alone.

## 1.17.0

- **Walking away from a run now leaves a note you can actually see.** The
  old "Cut short: the mailbox closed" fired at the exact moment the window
  was hiding - dead UI. Reopening the mailbox now greets you with
  "Remaining: N" (the run's own word, the live count) alongside any stuck
  line: "Remaining: 4 - Stuck: 1". It clears itself when a run finishes or
  the remainder is collected by hand, and deliberately does not survive a
  relog - by then the leftovers are ordinary inbox mail the segment counts
  already describe.

## 1.16.5

- **Relog survival no longer depends on HOW a mail got stuck.** The saved
  markers re-sync to the live registry every time the mailbox closes - so
  a refusal seen in a run you walked out of, a refusal from a single-click
  take, and a stuck mail from an earlier category all come back with their
  triangles after a relog, exactly like ones a finished run recorded. The
  sync also prunes markers whose mail was freed in the meantime.

## 1.16.4

- A run that collected nothing leads with the problem alone - "Stuck: 1",
  not "Collected: 0 - Stuck: 1". The green half only speaks when there is
  something green to say; a clean run over an empty category still reports
  its truthful zero.

## 1.16.3

- The "Last visit: N mails could not be taken" sentence is gone - fully
  superseded by the revived markers. After a relog the stuck mails wear
  their triangles and the ordinary "Stuck: N" line, same as a same-session
  reopen; the old sentence only ever fired when the saved fingerprints
  matched nothing, which almost always meant the problem had resolved
  itself - stale numbers at the moment they stopped being true.

## 1.16.2

- The run outcome wears one colour per fact now: Collected in green, Stuck
  in amber (or Incomplete in red), the divider neutral - instead of the
  whole line taking the problem's colour and painting the good news amber.

## 1.16.1

- The Manage Recipients bundle sits on a quiet accent glow now - static, no
  pulse - so the card's loudest button finally looks the part. Follows the
  live accent, including a host UI's own colour.

## 1.16.0

- **Tab in the recipient field is two presses again, reliably.** The first
  Tab accepts the completion, the next steps down the list - and a roster
  tick refreshing the open popup (a Battle.net friend's presence changing)
  no longer resets that conversation halfway, which is what sometimes made
  the second press a silent no-op.
- **The popup now shows what Tab is holding**: the row behind the completion
  in the box wears an accent bar and a faint wash, and it moves as you
  cycle.
- **The Mail tab caption defaults to Nothing** and its button now tells the
  truth at a glance: it reads "Mail tab caption" while off, and the chosen
  mode's name once one is on. The list is reordered (Dot indicator, Total
  only, Collect / total, Nothing) and every dropdown in the addon now marks
  its current selection with an accent bar.
- The Manage Recipients portrait lines up exactly with the caption button
  beneath it, its bundle icon grew to 50px, and its title is a point larger.

## 1.15.1

- Fixed the options panel erroring on open (1.15.0): the caption row and
  the recipients portrait anchored to each other - one axis each, but the
  client refuses any cycle between two regions. The row now takes its right
  edge from the card, same arithmetic, one-way dependency.

## 1.15.0

- The General card reads as two clean columns again: the Mail-tab-caption
  control is a single full-width button under the checkboxes wearing its
  own name ("Mail tab caption" - the current choice lives in its list and
  tooltip), and the Manage Recipients portrait stretches to end level with
  it.
- The bug-report window's close button is the same small X as the options
  panel's (it was the stock art at full size), and the diagnostic report
  scrolls inside its box instead of spilling out of the window.

## 1.14.2

- **Fixed: no mail icon for mail that arrived after a fresh login** (with
  the minimap icon on under EllesmereUI). Their mail button is built with
  no anchor points and only gets them from a layout pass that skips hidden
  buttons - so after logging in with no unread mail, the button Postbox
  showed had nowhere to render until the next reload happened to anchor it.
  Postbox now fires their layout once, invisibly, the first time it shows
  an unanchored button. Cost: one layout poke per session, versus the
  per-mail-event relayouts the flicker fix removed.

## 1.14.1

- **The run outcome reports the whole run now.** Every finish leads with
  "Collected: N" - alone in green when everything came out, "Collected: 12
  - Stuck: 1" when something would not, "Collected: 12 - Incomplete: 3
  left" when the run stopped early. The count is this session's report and
  deliberately does not survive closing the mailbox; a reopen shows only
  what is still actionable.
- /postbox debug now includes the minimap module's live state (mode,
  suppression, finder retries, fallback latch, mail flag) - so if the icon
  ever misbehaves again, one paste tells the whole story.

## 1.14.0

- **Stuck mail speaks with one voice now.** The run-ending line, the
  same-session summary and the after-relog summary all say "Stuck: N" - one
  situation, one vocabulary - and hovering the status line lists exactly
  which mails and what the game said, in the same words the row tooltips use.
- **The warning triangles survive a relog.** The saved last-run record now
  carries the stuck mails' fingerprints, and the next session revives them
  into the live registry at the first mailbox open - so after a relog the
  troublesome mail wears its triangle again, not just a sentence in the
  corner. Entries whose mail was collected, returned or expired in the
  meantime never show; the record stays a handful of strings.
- **The Mail tab's caption is now a choice.** A new dropdown in General:
  still-to-collect over total (the default), just the total, a quiet accent
  dot while anything waits, or nothing at all. The segments keep their own
  counts checkbox.
- The icon picker sits one pixel higher, flush with the preview stage.

## 1.13.1

- The Mail tab's caption no longer doubles over itself under a host skin.
  Dynamic tab text now goes through the theme, which re-runs the skin's own
  repaint: EllesmereUI's engine mirrors the label and hides the original
  once, and a bare SetText was resurrecting the original beneath the mirror
  so both rendered at once.
- The status line is bounded between the window title and the close button
  now, so the long "Last visit" summary truncates with an ellipsis instead
  of running under the title - and hovering it shows the full line whenever
  it is truncated.
- The tab's count suffix drops to the quiet grey when nothing is left to
  collect: a full-strength (0/4) glanced from the Send tab read as "you've
  got mail" when the truth is "four read mails are sitting there".

## 1.13.0

- The main tab is called **Mail** now, and while the mailbox is open it
  carries the inbox at a glance - "Mail (3/12)", still-to-collect over
  total - so from the Send tab you can see there is something worth
  collecting. It follows the same "counts" option as the segment captions
  and reads the same single inbox walk, so the numbers can never disagree.

## 1.12.0

- **Stock Blizzard UI gets its backgrounds back.** The options panel's
  section cards, the status band and the bug-report window were built
  without backdrop support, so the addon's own fill, border and grain
  silently skipped them - and the host skins painted them anyway, which hid
  the hole on a skinned setup. The paint pipeline now retrofits backdrop
  support to any frame it is asked to surface, so this cannot happen again.
- **"Last visit: N mails could not be taken" actually survives a relog.**
  The saved record was erased the moment the mailbox opened, because the
  inbox always reads empty before the first inbox update and that cold read
  was treated as truth. Erasure now waits for a real update.
- **No more minimap-bar flash when mail arrives** (with the minimap icon
  enabled under EllesmereUI). The default indicator is now silenced in skin
  mode too, so EllesmereUI's relayout hooks - whose layout pass flashes its
  mouseover-hidden button row for a beat - are never poked by mail events;
  Postbox drives their icon's visibility itself with the same call their own
  sync makes. The underlying flash is an EllesmereUI bug that also fires
  without Postbox; a report for their tracker is drafted.
- The finder for EllesmereUI's mail button no longer churns the default
  indicator around every mail event once its retries run out; if
  EllesmereUI rebuilds its button mid-session the old one is restored
  faithfully instead of keeping Postbox's art forever; and a retired icon
  style now falls back to Letter everywhere, so the minimap and the options
  panel agree.
- The bug-report window closes on Escape, opens centred when /postbox debug
  is the first thing that ever summons it, and its copy boxes can no longer
  be mangled with Backspace or Delete.
- The icon picker's scrollbar track survives host-UI skinning (it was a
  floating thumb with no rail).
- Manage Recipients and its tooltip are translated for deDE, esES and ruRU;
  the Send tab's doorway says so in chat if the recipient manager is
  unavailable; and the fourth icon source sheet no longer ships in the
  release zip.

## 1.11.4

- The Send tab's recipient-manager control is a true inline segment now:
  flush with the field's right end, enclosed by the field's own edges, a
  hairline divider on its left, and typed text stops short of it.

## 1.11.3

- The bundle icon actually shows on the Manage Recipients button and the
  Send tab's doorway: both icons now ride art-holder child frames, out of
  reach of the host skin's button repaint that was fading them.
- The bug-report window uses the standard close button, same as the
  options panel's.

## 1.11.2

- The Send tab's recipient-manager doorway is a proper plated button with
  the bundle icon inset, and the big Manage Recipients button shows the
  same icon full-strength between its title and count.
- The EllesmereUI mode line is centred, and a disabled minimap card stops
  its preview pulse instead of breathing at 40% opacity.

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
