# Combat Taint Issue — Mailbox open/close in combat (retail 12.0+)

> Status: **known, benign, unresolved.** The addon is fully functional. These are
> log-only errors that occur **only** when opening/closing the mailbox **while in
> combat**. Documented here so a future fix attempt doesn't start from zero.
>
> Last investigated against **Interface 120001 (The War Within / "Midnight" 12.0.x)**.
> Committed working state at time of writing: `e8f6999`.
>
> **Re-checked for 12.1 (Curse of Ula'tek, 2026-08-11, Interface 120100).** The 12.0.5 /
> 12.0.7 / 12.1 API change lists contain **no** changes to the mail APIs, the UI-panel
> functions (`SetUIPanelAttribute`, `UpdateUIPanelPositions`, `HideUIPanel`), or
> `PlayerInteractionFrameManager`. 12.1's addon work is the aura "disarmament"
> (`AuraContainer`/`AuraButton`, forbidden aura buttons), which Postbox does not touch.
> So everything below still stands unchanged — no new taint vectors.
>
> **§7 fix #3 is now implemented** (see §7). Two taint sources are gone with it: the
> close no longer writes to `MailFrame` at all, and the `MailFrame:HookScript("OnShow", …)`
> that tainted the frame at login has been removed. `MailFrame:SetAlpha(0)` on open and
> the grid reservation remain, so **the in-combat open error is unchanged** — see the
> "important caveat" in §7 #3.
>
> **Correction to an earlier note here.** `FrameScriptObject:CanBeAccessedInContext` and
> `HasAccessConstraints` (12.1; absent on live 12.0.7) are **not** the taint probe this
> header once hoped for.
> * Both are declared `SecretReturnsForAspect = { Enum.SecretAspect.ObjectSecurity }`, so
>   in tainted execution — exactly when you would want to ask — the returned boolean can
>   be a **Secret value**, and branching on a secret raises. Any use needs an
>   `issecretvalue()` / `canaccessvalue()` guard, never a bare `if`.
> * They answer *"is this object forbidden / access-restricted"*, **not** *"will
>   `HideUIPanel` on it be blocked right now"*. They are not a substitute for
>   `InCombatLockdown()` and they cannot tell you whether a frame is tainted.
>
> They do replace `CanAccessObject`, which was never a C API in the first place: it was a
> plain FrameXML global, `function CanAccessObject(obj) return issecure() or not obj:IsForbidden() end`,
> in `Blizzard_DebugTools/DebugObjectUtil.lua` — a file 12.1 deletes, with Blizzard's own
> call sites migrated to `obj:CanBeAccessedInContext()`. Postbox does not use it.

---

## 1. Symptoms

Two distinct errors, both only in combat, both rooted in the same cause.

### A. Opening the mailbox in combat (after the first open)

```
[ADDON_ACTION_BLOCKED] AddOn 'Postbox' tried to call the protected function 'SendMailFrame:Hide()'.
[C]: in function 'Hide'
[Blizzard_MailFrame/MailFrame.lua]:140: in function 'MailFrameTab_OnClick'
[Blizzard_MailFrame/MailFrame.lua]:65: in function 'showFunc'
[Blizzard_UIPanels_Game/Shared/PlayerInteractionFrameManager.lua]:246: in function 'ShowFrame'
[Blizzard_UIPanels_Game/Shared/PlayerInteractionFrameManager.lua]:284: in function <...PlayerInteractionFrameManager.lua:281>
[C]: in function 'TurnOrActionStop'
[TURNORACTION]:4: in function <[string "TURNORACTION"]:1>
```

Key fact: **the stack is 100% Blizzard code.** No Postbox frame appears in it.
The function being blocked (`SendMailFrame:Hide()`) is called by Blizzard's own
mailbox-open path. It is blamed on Postbox because Postbox **tainted `MailFrame`
earlier**, and Blizzard's code touches `MailFrame` here.

The mailbox still opens — `SendMailFrame:Hide()` is just hiding an already-hidden
sub-frame, so the failed call has no visible effect.

### B. Closing the mailbox with ESC in combat

`Interface action failed because of an AddOn` (red `UIErrorsFrame` text in chat).
Closing with the **close button does not** produce this — see §4.

---

## 2. The decisive diagnostic

Run after a fresh `/reload` (a reload wipes all taint for the session):

| Step | Result |
|---|---|
| Enter combat, open mailbox for the **first time** in combat | **Clean — no error** |
| Close it (still in combat), open it **again** | **Error appears** |
| Then ESC-close | **"Interface action failed"** |

This isolates the cause precisely:

- The **first** open is clean because `HookScript` runs our `OnShow` handler **after**
  Blizzard's original. So Blizzard's `MailFrameTab_OnClick → SendMailFrame:Hide()`
  executes on a still-clean `MailFrame` first. *Then* our hook runs and taints it.
- Our hook calls `HideMailFrame()` → `MailFrame:SetAlpha(0)`. **That insecure write
  taints `MailFrame`** for the rest of the session.
- The **second** open: Blizzard's `MailFrameTab_OnClick` reads the now-tainted
  `MailFrame`, the execution becomes tainted, and `SendMailFrame:Hide()` (a protected
  op in combat) is blocked.
- Same tainted `MailFrame` is why ESC-close (which routes through the interaction
  manager and touches `MailFrame`) then fails.

Crucially, in this combat-only test the **grid space-reservation was NOT involved**
— it is deferred while in combat (see §4). The hide alone reproduced it.

---

## 3. Background a fixer needs: WoW taint + the 12.0 mail rework

### 3.1 The taint model (the part that actually matters here)

- Execution starts **secure** when triggered by a hardware event (keypress, click).
- When **insecure** (addon) code runs in that path, or writes to a frame, taint spreads.
- **Writing to a frame from insecure code taints that frame** (the object), and the
  taint **persists for the whole session** (until `/reload` or relog).
- When **secure** code later **reads or uses a tainted frame/value**, the secure
  execution becomes tainted too.
- A **protected action** (e.g. `Show`/`Hide`/`SetPoint` on a protected frame, or
  setting protected attributes) called from a tainted execution is **blocked** —
  but **only while `InCombatLockdown()` is true**. Out of combat the same code runs
  fine (which is why everything works peacefully and only combat trips it).
- `ADDON_ACTION_BLOCKED` fires and names the addon whose taint reached the blocked call.
- `securecall()` and `hooksecurefunc()` isolate taint from the secure caller.
  **`frame:HookScript()` does not** — our hook’s writes taint the frame itself.

Practical consequence for us: **any** insecure write to `MailFrame` (`SetAlpha`,
`Hide`, `SetUIPanelAttribute`, `SetPoint` on `MailFrame` itself, etc.) permanently
taints it, and the **next in-combat** mailbox open/close then fails inside Blizzard’s
own code.

### 3.2 What changed in 12.0 (why this is "new")

- The mailbox is now a **player interaction** driven by
  `Blizzard_UIPanels_Game/Shared/PlayerInteractionFrameManager.lua`
  (`Enum.PlayerInteractionType.MailInfo`, numeric value **17**).
- Opening it goes `TurnOrActionStop → PlayerInteractionFrameManager:ShowFrame →
  showFunc → MailFrameTab_OnClick`. That Blizzard chain **reads/writes `MailFrame`
  and `SendMailFrame`** as part of normal open, so any prior taint on those frames
  detonates here.
- These interaction frames are more strictly secured than the pre-11.0 `UIPanel`
  era. Touching them from an addon is far more taint-sensitive than it used to be.
- The mailbox close also runs through the interaction manager (fires
  `PLAYER_INTERACTION_MANAGER_FRAME_HIDE` with arg 17 / `MailInfo`, and `MAIL_CLOSED`).

---

## 4. Where Postbox touches `MailFrame` (the taint sources)

All in `Core/MailboxUI.lua` unless noted. Postbox’s whole design = hide the native
`MailFrame` and overlay our own window, which inherently means writing to `MailFrame`.

| Write | Function | When | Taints? | Combat-guarded? |
|---|---|---|---|---|
| `MailFrame:SetAlpha(0)` | `HideNativeMailFrame` | every open | **yes** (confirmed culprit) | no — runs always |
| `SetUIPanelAttribute(MailFrame,"width",..)` + `UpdateUIPanelPositions(MailFrame)` | `ReserveGridWidth` (grid space-reservation) | every open (grid mode on) | **yes** | yes — deferred via `InCombatLockdown()`, re-applied on `PLAYER_REGEN_ENABLED` |
| `frame:SetPoint("TOPLEFT", MailFrame, ...)` | `DockToSlot` (grid positioning) | open | **no** — anchoring *our* frame to MailFrame only reads MailFrame; does not taint it | n/a |

**Removed by §7 fix #3** (kept here because the reasoning matters if anyone reinstates them):

| Was | Where | Why it is gone |
|---|---|---|
| `HideUIPanel(MailFrame)` (calls `UpdateUIPanelPositions`) | `CloseMailbox`, out of combat | `CloseMail()` is now the whole close, in combat and out. Blizzard's own `MailFrame_Hide` reaches the *same* `HideUIPanel(MailFrame)` from secure execution, so the panel is still released — without the taint. |
| `MailFrame:SetAlpha(1)` + `MailFrame:Hide()` | `OnMailClosed`, out of combat | Blizzard performs the hide. Restoring alpha only to hide again bought a "tidy" state nothing reads, and made the frame visible at a moment when re-hiding it is not guaranteed to be allowed. |
| `MailFrame:HookScript("OnShow", …)` | `UI.Initialize` | Installing a script handler on a protected frame from insecure code is itself a write to it — this tainted `MailFrame` at **login**, before any mailbox was opened. It was also redundant: `MAIL_SHOW` and `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` are both registered, both call `OnMailShow`, and Blizzard's only route to showing `MailFrame` is `PlayerInteractionFrameManager:ShowFrame → MailFrame_Show`, which that interaction event drives. |

Notes:
- **Grid positioning (`DockToSlot`) is taint-free** and independent of reservation.
  The "window opens where the mailbox is / snaps after resize" behavior is this.
- **Grid space-reservation (`ReserveGridWidth`)** — making other Blizzard
  panels reserve room around Postbox — is the part that structurally taints. It is
  confirmed to still *work* visually in 12.0 (other panels do reserve space), so it
  is a real feature, not dead weight. This is now the **only** protected write left,
  and it is the only reason `InCombatLockdown()` is still consulted anywhere.
- Every close — close button, ESC, walking away — goes through `CloseMail()` (a
  plain C API that touches no frame), never the `HideUIPanel` path that reads the
  tainted `MailFrame`. Combat no longer changes the close path in any way.
- **Function names in this document have moved on.** `HideMailFrame`/`RestoreMailFrame`
  are `HideNativeMailFrame`/`ShowNativeMailFrame` (the latter no longer exists) and
  `SetMailFrameSpacerWidth` is `ReserveGridWidth`. Named here so the old names remain
  greppable against the history.

`Core/SendTab.lua`: `ActivateNativeSendMail`/`DeactivateNativeSendMail` used to
`SendMailFrame:Show()/:Hide()` and `PanelTemplates_SetTab(MailFrame, ..)`. **Those
were removed** — they tainted `SendMailFrame`/`MailFrame` and were purely cosmetic
(the native frame is invisible). Right-click-to-attach only needs
`SetSendMailShowing(true)` (a non-frame C API, taint-free). Removing them also fixed
a "needed two ESC presses on the Send tab" bug (the native send name editbox was
auto-focusing on `SendMailFrame:Show()` and eating the first ESC).

---

## 5. What we tried

| Attempt | Outcome |
|---|---|
| Defer `SetMailFrameSpacerWidth` in combat + re-apply on `PLAYER_REGEN_ENABLED` | Stops *our* call erroring in combat, but does **not** fix it — taint from earlier (peaceful) writes persists into combat. **Kept** (committed). |
| `CloseMail()` in combat instead of `HideUIPanel` | Close button works cleanly in combat. **Kept — and since superseded by fix #3, which uses `CloseMail()` unconditionally.** |
| ESC-close: defer `CloseMailbox` off the secure ESC keypath (`OnHide → C_Timer.After(0)`) | Makes ESC actually close the mailbox (it previously orphaned the interaction). **Kept.** |
| Skip touching `MailFrame` in `OnMailClosed` while in combat | **Kept — and since superseded by fix #3, which does not touch it at all.** |
| **Fix #3, implemented in full** — `CloseMail()` always, no `HideUIPanel(MailFrame)`, no `MailFrame:Hide()`, no alpha restore, no `OnShow` hook | Close-side taint gone; behaviour unchanged. Does **not** silence the in-combat open error — see §7 #3. **Kept.** |
| Remove `SendMailFrame`/`InboxFrame`/`PanelTemplates_SetTab` writes from SendTab | Correct cleanup; removed a taint vector and fixed the double-ESC. **Kept.** Did **not** fix the open block (that’s `MailFrame` taint, not `SendMailFrame`). |
| **Secure-handler hide** — `SecureHandlerWrapScript(MailFrame, "OnShow", header, [[ self:SetAlpha(0) ]])` to hide in the secure sandbox (taint-free) | **FAILED / reverted.** `MailFrame` stayed **visible** behind Postbox. See §6. |
| Gutting the grid reservation entirely | Reverted — it’s a wanted, working feature; deleting it was the wrong call. |

The committed state (`e8f6999`) keeps every feature and all the *partial* combat
guards above; it accepts the residual log noise.

---

## 6. Why the secure-handler hide failed (leads for next time)

The theory is sound — a snippet running in the restricted/secure environment can
call `SetAlpha` **without tainting** the frame. But our attempt left `MailFrame`
visible. Unverified hypotheses, in rough order of likelihood:

1. **The interaction manager fades `MailFrame` in.** If `ShowFrame`/`showFunc`
   drives an alpha animation (or sets alpha) **after** `OnShow`, our single
   `OnShow` `SetAlpha(0)` is overridden. The *old insecure* hide "worked" only
   because it brute-forced `SetAlpha(0)` from **many** triggers (`OnMailShow`,
   `UI.Show`, `MAIL_SHOW`, `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`, the OnShow
   hook), re-applying after the fade. A one-shot secure snippet can’t do that.
   → **Verify:** does `MailFrame` have an alpha `AnimationGroup` that plays on show?
   Is alpha set in `showFunc` (MailFrame.lua:65) or in `ShowFrame`?
2. **`self` binding in the wrapped snippet.** Confirm whether, in
   `SecureHandlerWrapScript`’s pre/post body, `self` is the **wrapped frame**
   (MailFrame) or the **header**. If it’s the header, `self:SetAlpha(0)` did nothing
   to MailFrame. (Real-world usage suggests `self` = wrapped frame, but confirm.)
   Safer: `header:SetFrameRef("mail", MailFrame)` then `self:GetFrameRef("mail")`.
3. **`SetAlpha` not in the restricted method whitelist** for this frame/context →
   the snippet errors silently (the `pcall` only guards *setup*, not snippet runtime).
4. **Pre- vs post-body ordering.** We used the pre-body (runs before Blizzard’s
   OnShow). Try the post-body (5th arg) so our alpha set is last.

### Things to actually instrument before trying again
Add a temporary `/postbox debug` (or `print`) that, on each `MAIL_SHOW` /
`PLAYER_INTERACTION_MANAGER_FRAME_SHOW` and a frame or two later, logs:
`MailFrame:GetAlpha()`, `MailFrame:IsShown()`, `MailFrame:IsProtected()`,
`issecurevariable(MailFrame, ...)` if useful, and whether a show animation exists.
Flying blind on secure-handler internals is what cost us rounds here.

---

## 7. Candidate fixes (with trade-offs)

1. **Accept the noise (current).** Zero risk, all features. Errors only when
   opening/closing the mailbox mid-combat (rare).

2. **Secure-handler hide, done properly.** Fixes the `SetAlpha` taint cleanly and
   keeps every feature. Needs the §6 investigation (likely must defeat/disable a
   fade-in and/or re-apply). Note: this fixes the **hide** taint only — a *peaceful*
   open still runs the reservation `SetUIPanelAttribute` write, which also taints,
   so peaceful-open-then-combat could still error unless reservation is addressed too.

3. **Make the close fully taint-free.** ✅ **IMPLEMENTED.**

   What changed, all in `Core/MailboxUI.lua`:
   - `CloseMailbox` is now `CloseMail()` unconditionally — in combat and out. If a
     client ever stops exporting that global it falls through to
     `C_PlayerInteractionManager.ClearInteraction(Enum.PlayerInteractionType.MailInfo)`,
     and only if *both* are missing does it reach a last-ditch `HideUIPanel(MailFrame)`,
     which cannot happen on a client that can open a mailbox at all. The old
     `if not MailFrame then return end` guard is gone: neither `CloseMail` nor
     `ClearInteraction` needs the frame, and bailing on a missing one would have left
     the interaction orphaned.
   - `OnMailClosed` no longer touches `MailFrame`. The `SetAlpha(1)` + `Hide()` pair
     and the in-combat `SetAlpha(0)` (which re-set an alpha that was already 0) are
     both gone; `ShowNativeMailFrame` was deleted with them. The frame stays at alpha
     0 for the session, which is what the next open wants anyway, and a `/reload`
     restores it.
   - `MailFrame:HookScript("OnShow", …)` is gone from `UI.Initialize` (see §4).

   Everything else is preserved: the close button, ESC (still deferred a frame off
   the secure keypath with `C_Timer.After(0)`), walking away, and the deferred grid
   reservation.

   *Why it is behaviour-neutral*, traced through the shipped Blizzard source
   (12.0.7.68887): `MailFrame`'s XML `OnHide` handler
   (`Blizzard_MailFrame/MailFrame.xml:864-872`) calls `CloseMail()` itself, then
   `HideUIPanel(OpenMailFrame)`, clears the three send-mail edit boxes, plays the
   close sound and calls `SetSendMailShowing(false)`. `CloseMail()` ends the
   interaction, which fires `PLAYER_INTERACTION_MANAGER_FRAME_HIDE`;
   `PlayerInteractionFrameManagerMixin:HideFrame`
   (`PlayerInteractionFrameManager.lua:253-273`) looks up
   `[Enum.PlayerInteractionType.MailInfo] = { frame = "MailFrame", hideFunc = "MailFrame_Hide" }`
   and calls `MailFrame_Hide()`, which is `HideUIPanel(MailFrame)`
   (`Blizzard_MailFrame/MailFrame.lua:71-76`) plus `C_ChatInfo.CancelEmote()` and
   `CloseAllBags()`. So the two paths **converge on the same `HideUIPanel(MailFrame)`**;
   the only difference is whether *we* call it (insecure, taints) or Blizzard's own
   secure handler does (does not). The feared "out-of-combat close leaving the UIPanel
   layout engine confused" does not materialise — the panel is released, by Blizzard,
   on the same frame.

   *What to watch for in game.* Close with the X, then open the character sheet or
   the bags: do other UI panels sit correctly, or offset as if an invisible window
   were still docked? (That is the one real risk and the thing that would disprove
   the convergence above.) Close with ESC: does the mailbox actually shut, and does
   the emote/close sound still play? Reopen in the same session: does `MailFrame`
   stay invisible now that the alpha is never restored?

   *The important caveat.* This removes the **close-side** taint only. §2's decisive
   diagnostic pinned the session-poisoning write on the **open-side**
   `HideNativeMailFrame()` → `MailFrame:SetAlpha(0)`, which still runs on every open,
   plus the reservation `SetUIPanelAttribute` in §4. So #3 does **not** stop the
   `ADDON_ACTION_BLOCKED` on an in-combat open, and it was never going to. It is
   hygiene, and a prerequisite for a real fix.

4. **Reservation without tainting `MailFrame`.** The space reservation is the one
   piece that *cannot* be done in a secure snippet (`SetUIPanelAttribute` /
   `UpdateUIPanelPositions` aren’t in the restricted env). Options:
   - Register **our own** `PostboxFrame` in `UIPanelWindows` so *it* reserves space,
     instead of overriding `MailFrame`’s width. But `ShowUIPanel`/`HideUIPanel` are
     protected in combat, and this changes our window’s whole lifecycle — significant
     rework, needs care.
   - Accept that reservation ⇒ taint, and make it a user toggle ("reserve space —
     may log a harmless error if you open the mailbox in combat").

5. **Cover instead of hide.** Don’t write to `MailFrame` at all; place an opaque
   frame *we* own, sized to `MailFrame`’s rect (reading its size is taint-free),
   between `MailFrame` and Postbox. Fully taint-free. Risk: where `MailFrame` extends
   past Postbox (it can be taller than the default 440px window), the cover shows as
   a plain rectangle — needs visual care, and must track MailFrame’s size/position.

6. **Replace the interaction frame.** ⭐ **Viable, and the strongest lead in this
   document.** Worth a spike before any more effort goes into #2.

   The earlier reading — "`InteractionManagerFrameInfo` is file-local, there is no
   registration function, dead end" — is true as far as it goes and **misses how the
   handlers are resolved**. The entry is declared with *string* names:

   ```lua
   [Enum.PlayerInteractionType.MailInfo] = {
       frame = "MailFrame", showFunc = "MailFrame_Show", hideFunc = "MailFrame_Hide"
   },
   ```

   and `ShowFrame` / `HideFrame` resolve them **lazily out of `_G` on first use**,
   caching the result back into the table
   (`PlayerInteractionFrameManager.lua:241-247`, `:265-271`):

   ```lua
   if type(frameInfo.showFunc) == "string" then
       frameInfo.showFunc = _G[frameInfo.showFunc];
   end
   ```

   So replacing the globals `MailFrame_Show` and `MailFrame_Hide` before the first
   mailbox interaction of the session makes the manager call **our** functions, and
   `MailFrame` is **never shown at all**. No hook of the manager, no `SetAlpha`, no
   `Hide`, no `HookScript` — every §4 taint source except the grid reservation
   disappears at once. Our replacement runs as tainted code called from secure
   execution, which does not taint `MailFrame` (we never touch it) and is fine as long
   as the replacement does nothing protected, which it need not.

   **Costs, all of which need deciding before anyone builds this:**
   - **Timing is one-shot.** The replacement must be installed before the first
     `ShowFrame` for `MailInfo`; after that the table holds a function reference and
     swapping the global does nothing. `PLAYER_LOGIN` is early enough.
   - **It is an unsupported de-facto mechanism**, not an API. It can break on any
     patch, and it is hostile to other addons that `hooksecurefunc("MailFrame_Show", …)`
     — chain to the original rather than discarding it if that matters.
   - **Blizzard's own mailbox setup stops running.** `MailFrame_Show`
     (`Blizzard_MailFrame/MailFrame.lua:52-68`) does `ShowUIPanel(MailFrame)`,
     `C_GuildInfo.GuildRoster()` when the roster is empty, `OpenAllBags(MailFrame)`,
     `SendMailFrame_Update()`, `MailFrameTab_OnClick(nil, 1)`,
     `MailFrame_RefreshInbox()` and `C_ChatInfo.PerformEmote("READ")`. Postbox would
     have to re-implement, item by item, whichever of those it wants: it already does
     its own roster request and its own inbox refresh, but the bag-opening and the
     read emote are user-visible. `MailFrame_Hide` (`:71-76`) does `CancelEmote`,
     `HideUIPanel(MailFrame)`, `CloseAllBags`, `SendMailFrameLockSendMail:Hide()` and
     `StaticPopup_Hide("CONFIRM_MAIL_ITEM_UNREFUNDABLE")`.
   - **It kills the grid reservation, and that is the real cost.** The whole mechanism
     (§4) works by overriding the width of a `MailFrame` that is *in the UI-panel
     layout*. If `MailFrame` is never shown there is no slot to reserve and no frame to
     dock against — `DockToSlot` anchors to `MailFrame`'s rect. So this pairs
     **mandatorily** with #4's first option (register `PostboxFrame` in `UIPanelWindows`
     so it reserves its own space), which is the significant rework #4 already flags.

**#6 + #4(own-frame)** is a genuinely taint-free architecture and is strictly better
than the **#2 + #3** combo this document used to propose: it removes the taint at the
source rather than routing around it. It is also more work. #3 is done and was worth
doing either way — it is a prerequisite for both routes.

---

## 8. Key references

- `Core/MailboxUI.lua` — `HideNativeMailFrame` (was `HideMailFrame`), `ReserveGridWidth`
  (was `SetMailFrameSpacerWidth`), `DockToSlot`, `ApplyWindowLayout`, `CloseMailbox`,
  `OnMailShow`/`OnMailClosed`, `UI.Initialize` (the event registrations).
- `Core/SendTab.lua` — `ActivateNativeSendMail`/`DeactivateNativeSendMail`,
  `SetSendMailShowing`.
- Blizzard: `Blizzard_MailFrame/MailFrame.lua` (`MailFrameTab_OnClick`, `showFunc`),
  `Blizzard_UIPanels_Game/Shared/PlayerInteractionFrameManager.lua` (`ShowFrame`),
  `FrameXML/SecureHandlers.lua` (`SecureHandlerWrapScript`, `SecureHandlerSetFrameRef`,
  `SecureHandlerExecute`, restricted-environment method whitelist).
- APIs: `InCombatLockdown()`, `CloseMail()`,
  `C_PlayerInteractionManager.ClearInteraction(Enum.PlayerInteractionType.MailInfo)`,
  `Enum.PlayerInteractionType.MailInfo` (== 17), `SetSendMailShowing()`,
  `issecurevariable()`.

## 9. One-line summary for future-you

> Postbox hides the native, now-secure `MailFrame` by writing to it (`SetAlpha` on
> open, plus `SetUIPanelAttribute` for grid reservation — those two are all that is
> left). Any such write taints `MailFrame` for the session; Blizzard’s own mail
> open/close code then reads that tainted frame and is **blocked in combat**. The
> close side is now fully taint-free (§7 #3, implemented). The remaining routes are a
> secure snippet (finicky — fights the interaction-manager fade), covering it with our
> own frame, or — the best lead — replacing the globals `MailFrame_Show`/`MailFrame_Hide`
> before the first mailbox so `MailFrame` is never shown at all (§7 #6), which forces
> the own-frame reservation rework (§7 #4). Everything works; the errors are
> combat-edge log noise.
