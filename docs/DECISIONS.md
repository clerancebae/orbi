# Decisions & known limitations

## Project generated with XcodeGen (deviation from spec §8)
Spec said to use XcodeGen only if already installed, otherwise ask. The owner asked Claude to set it up without manual Xcode steps, so XcodeGen 2.46 was installed via Homebrew. It's a dev tool only; the app still has zero third-party dependencies. `project.yml` is the source of truth; `Orbi.xcodeproj` is generated.

## App Group ID is team-prefixed: `NB6868HT2X.com.berke.orbi`
On macOS, a `<TeamID>.`-prefixed group needs no developer-portal registration or provisioning profile, and avoids the "would like to access data from other apps" prompt that macOS 15+ shows for unregistered `group.` IDs. It's written as `$(TeamIdentifierPrefix)com.berke.orbi` in entitlements and injected into Info.plist (`OrbiAppGroupID`) so code reads it rather than hard-coding the team. The Safari extension (Phase 5) must use the same group.

## Store fallbacks
- If the group container is unavailable, `SharedContainer` falls back to the app's Application Support (logged).
- If the SwiftData store can't be opened, the app runs on an in-memory store and shows "Data not saved" in the panel instead of crashing.

## Swift 6 language mode
Enabled for both targets. `SharedContainer.defaults` is `nonisolated(unsafe)` because `UserDefaults` is thread-safe but not marked `Sendable`.

## Hardened Runtime on
Enabled from the start (harmless for local use; required if the app is ever notarized).

## Measurements
- Phase 0, Debug build, idle with panel closed: 0.0% CPU, ~38 MB RSS (`ps`). Instruments run is still pending (Phase 6).
- **Phase 3, Release build from /Applications, idle, panel closed, no active task (2026-11-07):** `phys_footprint` **11 MB**, CPU **0.0%**, **1 idle wakeup in 60 s**, 3 threads (`footprint`, `top -stats cpu,idlew`). `status.json` is written only on change.
- Same session, Debug build under the Xcode debugger: ~27–30 MB, with CPU spikes only right after launch or while using the panel. Use Release numbers for real-world cost.

## Phase 1 — Tasks

### `TaskItem.spentSeconds` (added to the spec's model)
Starting another task pauses the current one (spec §4). With only `startedAt`, a resumed task would lose its earlier time, so elapsed = `spentSeconds` (banked on pause/complete) + time since `startedAt`. Added with a default value so SwiftData migrates the Phase 0 store automatically (verified: `ZSPENTSECONDS` column appeared, no errors).

### Unfinished tasks roll over to today
On load / day change / wake, any non-done task from an earlier day moves to today (appended in order). Without this, a task left active overnight would vanish from "Today" yet still block the single-active rule. Done tasks stay on their day (for the Phase 6 daily summary).

### Menu bar label updates: a minute timer in `TaskStore`, not `TimelineView`
`TimelineView` inside a `MenuBarExtra` label doesn't reliably re-render. Instead `TaskStore` runs one repeating 60s `Timer` **only while a task is active** (none otherwise), aligned so it fires exactly when the displayed minute changes. Views compute times from `TaskStore.currentDate`, so they redraw only on ticks/actions. Also refreshes on `NSCalendarDayChanged` and wake from sleep.

### Label formatting
- With estimate: remaining rounded **up** (`59s` left → `1m`), so `0m` means time's up.
- Over estimate: icon switches to ⏰ and shows `+Nm`.
- No estimate: elapsed rounded down.
- Titles truncated to 18 characters including `…`.

### Quick-add estimate syntax
A trailing token only: `25m`, `25min`, `2h`, `1h30m`, `1h30`. A bare number (`Call 911`) is part of the title. The same parser will back `orbi://task/add` and quick capture.

### SwiftData predicates avoid enums
Filtering on `status` happens in memory after fetching by `plannedDate`. `#Predicate` comparisons on Codable enums are unreliable.

### "Ending soon" bubble (owner request, not in original spec)
When the active task's remaining time crosses **5 minutes** (downward), a small floating bubble appears top-right under the menu bar: **+5m / +15m / Finish** (and ✕ to dismiss), with a soft "Tink" sound.
- Custom non-activating `NSPanel` at `.statusBar` level, not a notification: it needs a decision, must not steal focus, and shouldn't be swallowed by Focus mode.
- Fires once per crossing. Starting a task or changing/extending its estimate only resets the baseline, so a task started with ≤ 5m never prompts immediately, and extending re-arms it.
- Tasks without an estimate never prompt. "Extend" on such a task sets estimate = elapsed + N.
- The bubble closes itself if the task is completed/paused/switched elsewhere.
- Not re-armed across app relaunch (baseline is in memory).
- Debug-only demo: `open build/Build/Products/Debug/Orbi.app --args -OrbiDemoBubble` (uses an in-memory store).
- Positioned under our own menu bar item with an arrow pointing at it (frame read from the app's `NSStatusBarWindow`, since MenuBarExtra doesn't expose its NSStatusItem). Falls back to the top-right of the main screen if that window can't be found. Clamped to the screen edges; the arrow follows the item.

## Phase 2 — Water, reminders, calendar

### Reminder timing
- `ReminderScheduler` keeps an **anchor** (last glass of water, or last reminder shown) and arms one `OneShotTimer` at `anchor + interval`, moved into working hours. Before the workday starts, the first reminder comes one interval into the workday (09:00 + 45m = 09:45), not at 09:00 sharp.
- Overdue (e.g. after sleep) fires immediately if it's within working hours; otherwise it's skipped and moved to the next workday. Timers never act early (guard against stray calls).
- On relaunch, the countdown continues from the last glass if it was within one interval; otherwise it restarts from launch time. So relaunching doesn't cause an instant reminder.
- Meeting deferral: at fire time, if a timed, busy, non-declined, non-cancelled calendar event is in progress, re-arm for its end + 2 min. Back-to-back meetings just defer again.
- "Snooze 15m" and meeting deferrals are an explicit override of the next fire time; logging water clears them.
- **Weekends:** "Also on weekends" defaults to **on**, so reminders work on any day out of the box; turn it off in Settings for weekdays only.

### Break suggestion = the bubble, not a notification
Spec §5.3 asks for one "water + 2 min break" notification when a task's estimate runs out. Since the owner prefers the bubble, the same bubble re-opens at time-up ("⏰ Time's up — finish, or need more time? Then take a water + 2 min break") instead of a separate notification. If both the 5-minute and the 0-minute points pass while asleep, only "time's up" shows.

### Label "reminder due" state
While a water reminder is waiting for an answer, the water part of the label shows `🔔💧5/8` (static, no animation) until water is logged or snoozed.

### Calendar
- Full access is requested at launch (macOS 14 `requestFullAccessToEvents`). Denied/write-only → next event and meeting deferral are simply off.
- "Next event" is limited to **today**; the label shows `📅 14:00` only when no task is active. `CalendarService` re-checks when that event starts, on `EKEventStoreChanged`, on day change, and when the panel opens.

### Settings
A small Settings window (water goal, glass size, reminder interval, working hours, weekends, permissions, launch at login), opened from the panel footer. Stored in the App Group `UserDefaults` suite. Phase 6 can extend it. Debug builds also have **"Send test reminder now"**.

### Water reminder is a bubble, not a system notification (owner request)
macOS always places notifications in the top-right corner; the owner wants reminders to come out of the menu bar item like the task bubble. `WaterReminderBubble` implements `WaterReminderPosting` and shows **💧 Water break — Snooze 15m / Drank ✓** under the item ("Glass" sound). It closes itself when water is logged or snoozed from anywhere.
- `BubblePresenter` is shared: bubbles are keyed ("task", "water"), stack downward with an 8pt gap, and only the top one has the arrow (verified with the demo: task bubble at y=32 h=137, water bubble at y=177).
- Trade-off: unlike notifications, bubbles are **not** silenced by Focus / Do Not Disturb, and they aren't in Notification Center history. `NotificationService` stays (permission status, and it's ready for the Phase 3 reading nudge or a fallback).

## Phase 3 — Read later, URL scheme, status export

### URL handling via `AppDelegate.application(_:open:)`
`AppEnvironment` is now owned by an `NSApplicationDelegateAdaptor` so it exists before any URL event arrives (including one that launches the app). `URLRouter` is pure parsing → `OrbiAction`; `AppEnvironment.perform` runs it through the same stores the panel uses. Malformed URLs are logged (`category: URLRouter`) and ignored.

### URL details beyond the spec table
- `task/add` also accepts `date=today|tomorrow|YYYY-MM-DD` (past dates land on today), so Claude/scripts can plan ahead. Without `min`, a trailing estimate in the title is parsed (`title=Write docs 25m`). `min` must be 1–1440. Titles capped at 300 chars.
- `reading/save` only accepts `http`/`https` URLs with a host (no `file:`, `javascript:`). Saving a URL that's already waiting returns the existing item.
- Query values: `+` means space; a literal plus must be `%2B`. Callers must URL-encode the `url` parameter.
- `orbi://capture` parses but is a logged no-op until the Phase 4 quick-capture panel.

### Future-dated tasks
Stored with their `plannedDate`; not shown in Today until that day (the existing day-change refresh picks them up). Exposed as `upcoming` in `status.json`.

### Read later
- "Open" sets `openedAt` (first time only) and clears a snooze; the row shows a book icon / "opened" in orange for opened-but-not-finished.
- Snooze: until tomorrow 09:00 or one week (`remindAfter`). Snoozed items stay in the list (dimmed) but are skipped by "open next" and the nudge.
- Pasted links get a fallback title of host + path; the app has no network entitlement, so page titles aren't fetched.

### Daily reading nudge = bubble
Same reasoning as the water reminder. One `OneShotTimer` at the configured time (default 21:00). The day is marked "checked" when it fires even if nothing was waiting, so it's never more than one per day. If the app starts after the time and today wasn't checked, it nudges right away.

### status.json
- Written atomically to the group container on any observed change (`withObservationTracking`, coalesced per run-loop turn), skipped if only `updatedAt` would differ. The once-per-minute task tick changes `remainingMin`, so it updates every minute while a task is active and not otherwise.
- Spec fields plus `elapsedMin`, `waterReminderDue`, `nextWaterReminder`, and lists `tasks` / `upcoming` / `reading` (for Claude/MCP). `remainingMin` is negative when over the estimate.
- Demo mode (`-OrbiDemoBubble`) doesn't write it.

### Finished reading items are kept (owner request)
"Done" no longer makes an item disappear. Today's finished items stay in the list struck through (✓ toggles back); older ones sit in a collapsed **Earlier read (N)** group with per-item delete and **Clear all** (only clears items finished before today). Nothing is auto-deleted. `status.json` has a `read` list (last 30) so Claude can answer "what did I read this week?". Saving a link that was finished before creates a new unfinished item.

### Verified at runtime (Phase 3)
Against the running app: `open "orbi://water/add"` → `status.json` water 3→4; `water/undo` → 3; an unknown route was ignored without a crash.

## Claude integration (MCP)

### Local stdio MCP server, not Claude API inside the app
`mcp/orbi_mcp.py` exposes Orbi to Claude Desktop / Claude Code using the user's own Claude account: no API key, no network entitlement for the app, and no third-party dependency (Python standard library, macOS system Python 3.9). It's a thin layer over the two public interfaces the app already has: it **reads `status.json`** and **writes via `orbi://` URLs**, so all validation stays in `URLRouter`/stores and the app needs no changes. Claude spawns it on demand, so it costs nothing while idle.
- `add_tasks` takes a list so "plan my day" is one tool call; each task is one URL.
- After an action it waits (≤ 2.5 s) for `status.json` to change and returns the fresh summary.
- Protocol: newline-delimited JSON-RPC 2.0; echoes the client's protocol version if supported, else the newest it knows. Notifications get no reply; unknown methods → -32601; tool failures are `isError: true` results, never a crash.
- Verified: 8 protocol tests (dry run) pass; end-to-end `log_water` → 4/4, `undo_water` → 3/4 against the running app; `claude mcp list` shows ✔ Connected.

### "Claude finished" bubble
New route `orbi://notify?title=…&message=…` (title or message required; capped at 120/240 chars) shows a bubble that closes itself after 10 s ("Glass" sound); a new notice replaces the old one and restarts the timer. Claude Code drives it through user-level `UserPromptSubmit`/`Stop` hooks, only for turns of ≥ 60 s so short replies don't pop bubbles. The script is generic (`mcp/agent_hook.py <agent> prompt|stop`, was `claude_hook.py`): Gemini CLI uses it via `BeforeAgent`/`AfterAgent`, and any agent with stdin-JSON hooks (Codex) can too; the bubble title uses the agent name. It always prints `{}` because Gemini parses hook stdout as JSON. Verified: pipe-tests (short turn → nothing, 3-min turn → correct URL, bad input → exit 0) and a real bubble appeared (300×73 under the item) and was gone after 12 s.

### status.json moved out of the App Group container (macOS 15 app data protection)
Claude Desktop's MCP process got "Operation not permitted" reading `~/Library/Group Containers/<group>/status.json`: since macOS Sequoia, group containers are readable only by apps from the same team (others need Full Disk Access). Touch Bar tools (BTT/MTMR) would hit the same wall. `status.json` now lives at **`~/Library/Application Support/Orbi/status.json`**, allowed by a single sandbox entitlement `com.apple.security.temporary-exception.files.home-relative-path.read-write = ["/Library/Application Support/Orbi/"]` (fine for a personal, non-App-Store app). The path is built from the real home (`getpwuid`), because inside the sandbox `NSHomeDirectory()` points to the app container. The SwiftData store stays in the group container (only Orbi and its future Safari extension need it). Verified: entitlement present in the signed app, file written there, MCP `log_water`/`undo_water` round-trip reads the new file.

### Approve and reply from the menu bar (`orbi://ask`)
User feedback: the most disruptive part of working with Claude Code is switching to the terminal to approve a command or give the next instruction. `orbi://ask?id&kind=permission|reply&title&message&detail` shows an interactive bubble (each id its own, so sessions stack); the answer is written to `~/Library/Application Support/Orbi/answers/<id>.json` (same sandbox-allowed folder as `status.json`), where `mcp/agent_hook.py` polls for it. `orbi://ask/cancel?id` closes it when answered elsewhere.
- **Permission** uses Claude Code's `PermissionRequest` hook: Allow/Deny become the hook decision; ✕/Terminal/timeout return nothing, so the normal prompt applies.
- **Reply** uses an async `Stop` hook with `asyncRewake`: it waits (≤ 1 h) in the background without blocking Claude; a reply exits 2 with the text on stderr, which wakes Claude. A new prompt typed in the terminal cancels the waiting hook (answer `cancelled`).
- The bubble panel can become key (text field) only when clicked; it never takes focus on its own, so typing in another app is never hijacked.
- Ids are `[A-Za-z0-9-]{1,64}` (they name files). Only the last message's first 3000 chars are shown; no summarizing (the app has no network and no model).

### Agents list (activity history)
Bubbles disappear, so what Claude said and what you approved was lost. `AgentLogStore` keeps a rolling log (newest first, last 100) in `agent-log.json` next to the SwiftData store: every `orbi://ask` (permission or reply) with its outcome (allowed / denied / terminal / replied / dismissed / elsewhere) and your reply, plus `orbi://agent/log?title&subtitle&detail`, which the hook sends for every finished turn that showed no reply bubble (short turns included). Plain JSON instead of a SwiftData model: it's a capped log, and this avoids a schema migration of the main store. The panel shows it as the first section ("Agents"); `status.json` carries the last 10 (detail cut to 300 chars) as `agents`, so `get_status` can answer "what did Claude do?". The first answer for an event wins, so the hook's cleanup cancel after a click doesn't overwrite it.

### Running agents, "go to app", daily summary
- **Running (🤖):** the hook sends `orbi://agent/start?session&agent&project&app` on every prompt; the turn ends with `agent/log` (or the reply `ask`), `agent/stop` (from `idle_prompt`, since `Stop` doesn't fire when a turn is interrupted), or after 3 h without news (closed terminal). Kept in memory only. The label shows `🤖`, `🤖N`, or `🔔🤖` while an ask bubble is open. Count only, no ticking minutes, so the label doesn't re-render every minute for agents.
- **Go to app (↗):** the hook passes the host app's bundle id (`__CFBundleIdentifier`, else `TERM_PROGRAM` mapped to a bundle id); Orbi activates it with `NSRunningApplication`. App-level only: focusing a specific window or tab would need Automation permission for every terminal.
- **Daily summary:** per-day totals (agent seconds, turns, projects, approved / denied / replies from Orbi) are stored in `agent-log.json` next to the events, for 30 days, so they aren't limited by the 100-event list. "Approved" counts only answers given in Orbi, not in the terminal.
- **Optional agent fields are lenient:** an invalid `session` / `app` / `seconds` is dropped, not an error, so an old hook still gets its bubble.

### Task clock pauses during sleep and screen lock (review fix)
An active task left running overnight came back with ~14 h elapsed, since elapsed time is `now − startedAt`. On `willSleep` and `com.apple.screenIsLocked`, the elapsed time is banked into `spentSeconds` and `startedAt` cleared (the task stays active); on wake / unlock, `startedAt` restarts from now.

### One-click connect (Settings → AI agents)
Competitors (Vibe Notch, Claude Status Bar, VibeBar) all install their hooks themselves; ours needed hand-edited JSON, our biggest onboarding gap. Now `agent_hook.py` and `orbi_mcp.py` ship as app resources, and `AgentConnections` edits `~/.claude/settings.json` / `~/.gemini/settings.json`:
- Sandbox access via two more home-relative temporary exceptions (`/.claude/`, `/.gemini/`). Fine outside the App Store; an App Store build would need a different approach (e.g. a "copy setup command" flow).
- `AgentHookConfig` (pure, tested) adds Orbi's entries next to the user's own and removes only entries whose command contains `agent_hook.py`. It never overwrites a file it can't parse; the first write keeps `settings.json.orbi-backup`. Output is pretty-printed with sorted keys, so the user's key order isn't kept, but values are.
- At launch, the copy in `/Applications` repairs hook paths that point at another copy of the script (app moved or replaced, or the old repo path). It never connects an agent that wasn't connected, and debug builds never repair, so they can't redirect hooks to a build folder.
- MCP stays copy-to-clipboard (`claude mcp add …` / JSON): `~/.claude.json` is large and rewritten by Claude Code all the time, and Claude Desktop rewrites its config itself, so writing them from Orbi would race.

### "Always" in the permission bubble
`PermissionRequest` input carries `permission_suggestions`, the rules behind the terminal's "Yes, and don't ask again". The hook shows **Always** when there is an allow suggestion (labelled like `Bash(npm test:*)`), and on click returns `allow` with those suggestions as `updatedPermissions`, the same as choosing it in the terminal.

### Review follow-ups: focus, a fallback switch, smaller files
- **Settings → Panel:** `showWater` / `showReading` hide those sections (and the water count in the menu bar). Hiding also turns their reminders off (`reminderSettings.enabled = remindersEnabled && showWater`, same for the reading nudge) without touching the reminder toggles themselves, so turning a section back on restores them.
- **Settings → AI agents → "Reply from the finished bubble":** the reply feature depends on Claude Code running an `asyncRewake` Stop hook in the background, which the docs don't spell out for `Stop`. If an update ever breaks that, this switch rewrites the connected hooks to a plain synchronous `stop` (a "finished" bubble with no reply field). Hook status now compares the exact set of Orbi commands, so a changed reply mode or script path shows as "Needs update".
- `AppEnvironment` was split: `AppEnvironment+URLActions.swift` (every `orbi://` action) and `AppEnvironment+Status.swift` (the `status.json` snapshot).
- Live checks: three Claude sessions at once (start, stop, idle) against the installed app. A real Gemini CLI turn couldn't run here (the account's Gemini setup fails with `IneligibleOrProjectIdError`); iTerm2 isn't installed; "go to app" was verified with Terminal and VS Code (`com.microsoft.VSCode`, from a bubble's ↗).

### Menu bar icon: the orbit is the status
The emoji label (🤖 🔔 🎯 ⏰ next to text) was replaced by an orbit icon drawn like the app icon (a planet inside a tilted orbit, 18 pt). Several rounds of drafts: a ring with a centre dot looked like a "record" button, and anything riding on the orbit cluttered it. The owner settled on "the orbit's colour and fill are the status", with no moon.
- States, by priority: **asking** (an agent waits for your answer, or a reply bubble is open) blue > **over** (active task past its estimate) orange > **progress** (active task with an estimate; the orbit fills in 5% steps) > **working** (an agent is mid-turn; solid orbit) > **idle** (faint orbit). `MenuBarIconState.current` is pure and tested.
- **Colour-blind safe:** no green or red. Normal states differ by luminance only (template images, tinted by macOS). The two attention colours are blue and orange, which common colour-vision deficiencies still tell apart, and "over" also shows `+4m` in the text.
- The label image needs `.renderingMode(.original)` for the coloured states: without it the menu bar label rendered it as a template, and blue / orange showed up monochrome (found in the real menu bar). Debug builds have `-OrbiMenuBarDemo`, which cycles every state every 4 s to check them in the real menu bar.
- Coloured states can't be template images, so the planet is drawn in the menu bar's text colour, read from Orbi's own `NSStatusBarWindow.effectiveAppearance` (KVO). Images are cached per state, and progress moves in 5% steps, so the icon redraws at most about once a minute.
- The text next to the icon is now plain: `API docs · 23m` / `+4m`, the next event `Standup 14:00`, and water `💧3/4` (hideable).

### Orbit simplified: agents only, "your turn" is blue (owner feedback)
Two problems showed up in real use: a finished turn didn't change the colour (it only went from solid to faint, easy to miss), and the solid "working" orbit looked like "100% done". The task-progress fill also confused things, because one ring meant both "Claude" and "your own task timer".
- The orbit now shows only agents: **idle** faint, **working** dashed (shape, not colour), **your turn** blue.
- "Your turn" = an open question or reply bubble, **or a finished turn you haven't seen** (`AgentLogStore.finishedUnseen`). It's cleared by that session's next prompt, by answering its reply bubble, or by opening the panel. An idle / interrupted stop doesn't count.
- Task progress and "over time" (orange) were removed from the icon; the task timer stays in the text (`API docs · 23m` / `+4m`). The debug `-OrbiMenuBarDemo` cycles the three states.

### Seven follow-ups: queue, shortcuts, limits, project tasks, Codex/OpenCode, week, focus
- **Queued message.** The panel writes `~/Library/Application Support/Orbi/queue/<session>.txt` (same allowed folder as `answers/`). When Claude's turn ends, `agent_hook.py stop` reads and deletes that file first, before deciding on a bubble. It sends the text as the next prompt: exit 2 + stderr when the Stop hook is async (`--reply`), or `{"decision":"block","reason":…}` when it isn't. It reports `agent/log?…&reply=` so Orbi logs it as a reply and puts the session back to "working". Claude only: other agents have no verified way to be woken.
- **Global shortcuts.** Carbon `RegisterEventHotKey` (no Accessibility permission). ⌥⌘Y / ⌥⌘N are registered only while a permission bubble is open, and ⌥⌘R only while a reply bubble is open; they act on the newest bubble. ⌥⌘R activates Orbi for the moment (`NSApp.activate()`; testing showed keystrokes still go to the front app when a non-activating panel is only made key) and focuses the reply field. When that bubble closes, the app you were in comes back to the front. Verified live: after ⌥⌘R the owner's typing landed in the bubble and was sent. Bubble placement with a hidden menu bar (auto-hide or full screen): the status item's window sits above the screen, which pushed bubbles partly off the top. Bubbles now always sit where the menu bar normally ends (`max(NSStatusBar.system.thickness, safeAreaInsets.top, frame.maxY − visibleFrame.maxY)`) and keep their arrow, so when the bar slides down the arrow points at Orbi's icon (checked with screenshots in both states). A first try that dropped the arrow and clamped to the visible frame looked off and was reverted. While the bar is hidden the arrow points at nothing; the owner chose to keep it that way. If another app owns a combination, registration fails quietly (logged).
- **Limit warnings.** `AgentLogStore.limitWarnings(old:new:)` is pure: at most one warning per window (the highest level crossed, 80 or 95). A reset time more than 2 min away from the old one counts as a new window that starts at 0 %.
- **Task ↔ project.** `TaskItem.project` (optional, so SwiftData migrates it automatically). It's set by `#tag` in quick add / `title=`, by `project=` on `task/add`, the MCP `project` field, or the row's Project menu. `agent/start` in a matching folder (case-insensitive) starts the first linked todo task, but only when nothing is active, so it never steals the clock. Agent seconds per project are kept in `AgentDayStats.projectSeconds` and exported as `agentMin` per task.
- **Codex.** Claude-style `UserPromptSubmit` / `Stop` in `~/.codex/hooks.json`, plus `[features] codex_hooks = true` in `config.toml` (line edit of that one key; one-time `.orbi-backup`; the flag stays when disconnecting). Based on third-party docs of the experimental hooks engine; **not verified with a real Codex install**.
- **OpenCode.** No command hooks, so a plugin goes in `~/.config/opencode/plugins/orbi.js`: `chat.message` → prompt, `session.idle` → stop, spawned detached so it never blocks. No last message, so the bubble shows only project and time. **Not verified with a real OpenCode install.** Two more sandbox exceptions: `/.codex/`, `/.config/opencode/`.
- **Week.** Calendar week (the user's first weekday). Agent totals come from the 30-day stats; tasks done and water are `fetchCount` since the week started. Computed when the panel opens and in each `status.json` snapshot.
- **Focus.** Off by default. While a task runs, a due water reminder is skipped and owed (`owedAfterQuiet`), and the reading nudge isn't re-armed. When nothing runs any more (`TaskStore.onActiveChange`), or focus is turned off, the owed reminder fires right away. Agent bubbles and the task's own "ending soon" bubble always show.
- Measured after install: idle CPU 0.0 %, phys_footprint 12 MB.

