# Orbi — Personal macOS Menu Bar Assistant

> This file is the project spec and working agreement for Claude Code. Read it fully before writing code.

## 1. What this is

A lightweight, personal-use macOS menu bar app that keeps my workday on track:

1. **Task planner** — today's tasks, one active task with a countdown timer.
2. **Water & break reminders** — smart, quiet, skips meetings.
3. **Read-later (bookmark) reminders** — save tabs, close them, get nudged to actually finish them.

Surfaces (all read/write the same data):

- **Menu bar** (primary): status label + dropdown panel.
- **Touch Bar** (secondary): buttons via BetterTouchTool/MTMR calling the app's URL scheme.
- **Global hotkey**: quick-capture panel.
- **Safari extension** (later phase): save current tab.

### Scope rules

- **macOS only. Personal use.** No App Store, no StoreKit, no onboarding, no analytics, no accounts, no iCloud sync (for now).
- Do **not** build an iPhone app.
- Every feature must serve the three core jobs above. No extra tools.

## 2. Tech stack

- Swift (Swift 6 language mode; if strict concurrency blocks progress, document it and use Swift 5 mode for that target).
- SwiftUI, `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
- SwiftData for persistence.
- UserNotifications for reminders.
- EventKit (read-only Calendar access) for next event + meeting detection.
- `SMAppService.mainApp` for launch at login.
- Carbon `RegisterEventHotKey` for the global hotkey (no third-party packages).
- App Intents (optional, Phase 4) so actions are available in Shortcuts.
- Safari Web Extension target (Phase 5).
- **No third-party dependencies.** Apple frameworks only.

Deployment target: **macOS 14.0+** (SwiftData requirement; my Mac has a Touch Bar).

App config:

- `LSUIElement = YES` (no Dock icon, menu bar only).
- App Sandbox **ON**, with an **App Group** (e.g. `group.com.yourname.orbi`) so the Safari extension and the Touch Bar status file share one data location.
- Entitlements: App Sandbox, App Groups, Calendars (read), User Notifications.
- URL scheme: `orbi://`.

## 3. Architecture

Single app target + (later) Safari extension target. Keep it simple: SwiftUI views → `@Observable` stores → services → SwiftData. No heavy patterns, no coordinators, no DI frameworks.

```
Orbi/
├── Orbi.xcodeproj
├── Orbi/
│   ├── App/
│   │   ├── OrbiApp.swift            # @main, MenuBarExtra, scenes
│   │   ├── AppEnvironment.swift       # builds ModelContainer + stores, injects them
│   │   └── URLRouter.swift            # parses orbi:// URLs → actions
│   ├── Models/                        # SwiftData @Model types
│   │   ├── TaskItem.swift
│   │   ├── WaterLog.swift
│   │   └── ReadingItem.swift
│   ├── Stores/                        # @Observable, @MainActor; UI-facing state + actions
│   │   ├── TaskStore.swift
│   │   ├── WaterStore.swift
│   │   └── ReadingStore.swift
│   ├── Services/
│   │   ├── ReminderScheduler.swift    # single one-shot timer to next due reminder
│   │   ├── NotificationService.swift  # UNUserNotificationCenter wrapper + actions
│   │   ├── CalendarService.swift      # EventKit: next event, "in meeting now?"
│   │   ├── StatusExporter.swift       # writes status.json for Touch Bar widgets
│   │   ├── HotKeyService.swift        # global hotkey via Carbon
│   │   └── LoginItemService.swift     # SMAppService
│   ├── Views/
│   │   ├── MenuBarLabel.swift         # the always-visible label
│   │   ├── PanelView.swift            # dropdown root
│   │   ├── TodaySection.swift
│   │   ├── WaterSection.swift
│   │   ├── ReadingSection.swift
│   │   ├── QuickCapturePanel.swift    # floating NSPanel for hotkey capture
│   │   └── SettingsView.swift
│   ├── Support/
│   │   ├── SharedContainer.swift      # App Group URLs (store + status.json)
│   │   └── DateHelpers.swift
│   └── Resources/ (Assets, Info.plist, entitlements)
├── OrbiSafariExtension/             # Phase 5
├── OrbiTests/
│   ├── URLRouterTests.swift
│   ├── ReminderSchedulerTests.swift
│   ├── TaskStoreTests.swift
│   └── WaterStoreTests.swift
├── TouchBar/
│   ├── README.md                      # how to set up BTT / MTMR buttons
│   └── scripts/                       # small shell/AppleScript helpers
└── docs/
    ├── DEVELOPMENT.md                 # how to build, run, test
    └── DECISIONS.md                   # non-obvious decisions + known limitations
```

### Data location

The SwiftData store and `status.json` live in the **App Group container** (`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`), so the Safari extension and external Touch Bar scripts can reach them.

## 4. Data models (SwiftData)

```swift
@Model final class TaskItem {
    var id: UUID
    var title: String
    var estimatedMinutes: Int?        // optional estimate
    var plannedDate: Date             // day it belongs to (start of day)
    var sortIndex: Int
    var status: TaskStatus            // .todo, .active, .done
    var startedAt: Date?              // set when it becomes active
    var completedAt: Date?
    var createdAt: Date
}

@Model final class WaterLog {
    var id: UUID
    var timestamp: Date
    var amountMl: Int                 // default glass size from settings
}

@Model final class ReadingItem {
    var id: UUID
    var url: URL
    var title: String
    var savedAt: Date
    var openedAt: Date?               // opened ≠ finished
    var finishedAt: Date?
    var estimatedMinutes: Int?        // optional, user-set or rough guess
    var remindAfter: Date?            // optional snooze
}
```

Settings via `@AppStorage` (UserDefaults, App Group suite):
daily water goal (glasses), glass size (ml), reminder interval (min), working hours (start/end), reading nudge time, hotkey, launch at login.

Rule: **only one task can be `.active`** at a time. Starting another task pauses (returns to `.todo`) the current one.

## 5. Features & behavior

### 5.1 Menu bar label (always visible)

Compact, single line, updates at most once per minute (`TimelineView(.periodic(from:by: 60))`), never per second.

- Active task: `🎯 <short title> · 23m   💧5/8`
- No active task: `📅 14:00` (next calendar event) or a plain icon + `💧5/8`
- Break due: icon briefly changes (no repeated animations).
- Truncate long titles (~18 chars).

### 5.2 Dropdown panel

- **Today**: task list (reorder, add, delete), start/complete buttons, active task with remaining time (estimate − elapsed; if no estimate, show elapsed).
- **Water**: `+1` button, progress `5/8`, undo last.
- **Read later**: unfinished items, newest first; actions: Open (sets `openedAt`), Done (sets `finishedAt`), Snooze, Delete. Show "opened but not finished" distinctly.
- **Footer**: next calendar event, quick-add field, Settings, Quit.

### 5.3 Water & break reminders

- Event-driven: `ReminderScheduler` computes the **next due time** and arms **one** one-shot timer (no polling loops).
- Only within working hours.
- When the timer fires: if `CalendarService.isInMeetingNow()` is true, **defer** to the meeting's end (+2 min) instead of notifying.
- Logging water (from any surface) resets the countdown.
- Notification has actions: **"Drank ✓"** (logs water) and **"Snooze 15m"**.
- When an active task's estimate runs out, suggest a short break ("water + 2 min break") in one notification. No notification spam.
- Respect system Focus/Do Not Disturb (the system handles suppression; don't fight it).

### 5.4 Read-later nudges

- Once per day at the configured time (default 21:00), if there are unfinished items: one notification, e.g. "3 items waiting — oldest saved 5 days ago." Action: **"Open next"**.
- Never more than one reading nudge per day.

### 5.5 URL scheme (Touch Bar + scripting interface)

| URL | Action |
|---|---|
| `orbi://water/add` | log one glass |
| `orbi://water/undo` | remove last log |
| `orbi://task/start-next` | start first `.todo` task today |
| `orbi://task/complete` | complete active task |
| `orbi://task/add?title=...&min=25` | add task for today |
| `orbi://reading/save?url=...&title=...` | save read-later item |
| `orbi://reading/open-next` | open oldest unfinished item |
| `orbi://capture` | show quick-capture panel |

- Validate every parameter; ignore malformed URLs safely (log, don't crash).
- `URLRouter` is pure parsing logic → fully unit tested.

### 5.6 Status export (for Touch Bar widgets)

- `StatusExporter` writes `status.json` to the App Group container **only when state changes** (and once per minute while a task is active):

```json
{ "activeTask": "API docs", "remainingMin": 23, "water": 5, "waterGoal": 8,
  "readingCount": 3, "nextEvent": "14:00 Standup", "updatedAt": "..." }
```

- BTT/MTMR script widgets read this file. Document exact paths in `TouchBar/README.md`.

### 5.7 Touch Bar

Use BetterTouchTool (or MTMR) — **not** private APIs in the app.

Buttons to document in `TouchBar/README.md`:

- 💧 `+1` → `open "orbi://water/add"`; label from `status.json` (`5/8`).
- 🎯 active task + remaining minutes; tap → `orbi://task/complete`.
- 🔖 Save Safari tab → AppleScript gets front Safari tab URL/title, then opens `orbi://reading/save?...` (URL-encode!).
- 📚 Reading count; tap → `orbi://reading/open-next`.

Provide the helper scripts in `TouchBar/scripts/`.

### 5.8 Quick capture (global hotkey)

- Default `⌥Space` (configurable).
- Floating `NSPanel`: one text field. Plain text → task for today. Text starting with `http` → read-later item.
- `Esc` closes, `Return` saves.

### 5.9 Safari extension (Phase 5)

- Toolbar button + context menu "Save for later".
- Uses native messaging (`browser.runtime.sendNativeMessage`) → `SafariWebExtensionHandler` writes a `ReadingItem` into the shared App Group store.
- Optional: "Save & close tab".

## 6. Performance & engineering rules

- Idle CPU ≈ 0. No polling, no per-second timers when the panel is closed.
- One reminder timer at a time; recompute on state changes.
- Keep memory small; measure with Instruments when done and record real numbers in `docs/DECISIONS.md`.
- Small SwiftUI views; logic lives in stores/services, not views.
- No force unwraps except where provably safe (comment why).
- Handle permission denial gracefully (Calendar denied → just hide next-event features; Notifications denied → show a hint in the panel).
- Unit-test: `URLRouter`, `ReminderScheduler` (inject a clock + calendar provider), `TaskStore` (single-active rule), `WaterStore` (daily count, undo).
- Never claim something works without building and testing it. Write what remains unverified.

## 7. Phases

Work **one phase at a time**. After each phase: build, run tests, fix errors, then stop and report (what works, what's unverified, how to test manually).

**Phase 0 — Skeleton**
Menu bar app runs with `LSUIElement`, placeholder label, panel opens, SwiftData container in App Group, launch-at-login toggle, `DEVELOPMENT.md`.
✅ App appears only in menu bar; quitting works; store file created in group container.

**Phase 1 — Tasks + timer**
TaskItem CRUD, reorder, single active task, menu bar label with remaining time.
✅ Start/complete tasks; label updates every minute; data survives relaunch.

**Phase 2 — Water + reminders + calendar**
WaterLog, `+1`/undo, ReminderScheduler, notifications with actions, CalendarService (next event, in-meeting deferral), working hours.
✅ Reminder fires on schedule; deferred during a calendar event; "Drank ✓" action logs water.

**Phase 3 — Read later + URL scheme + status export**
ReadingItem, panel section, daily nudge, URLRouter + all routes, StatusExporter.
✅ `open "orbi://water/add"` from Terminal works; `status.json` updates on change.

**Phase 4 — Touch Bar + quick capture**
`TouchBar/README.md` + scripts, global hotkey panel, optional App Intents.
✅ BTT buttons trigger actions and show live counts; hotkey capture saves tasks and links.

**Phase 5 — Safari extension**
✅ Saving a tab from Safari shows up in the panel immediately.

**Phase 6 — Polish**
Settings screen, daily summary (done vs. left), Instruments measurements, `DECISIONS.md` limitations.

## 8. Project setup notes for Claude Code

- If no Xcode project exists yet, ask me to create one in Xcode (macOS → App, SwiftUI, name `Orbi`), or use XcodeGen only if it's already installed. Don't hand-write `project.pbxproj` from scratch.
- Build/test from the terminal with `xcodebuild` (scheme `Orbi`) and report the exact results.
- Ask before adding any dependency (default answer: no).
- Keep `docs/DECISIONS.md` updated with every non-obvious choice.

Start with **Phase 0**.
