# Get On It — Technical Specification

| Field | Value |
|---|---|
| Status | Draft for review |
| Version | 0.1 |
| Date | 2026-10-21 |
| Platform | Android (first), Flutter |
| Slogan | *Do the thing.* |

---

## 1. Summary

Get On It is a goal and habit tracker for Android. The app does not create plans. Claude creates plans with a Claude skill. The skill writes a JSON document. The user sends the JSON to the phone. The app renders a native UI from the JSON and tracks progress.

The app has five main features:

1. **JSON UI.** The app renders screens, widgets, notifications, and alarms from JSON templates.
2. **Templates.** Each goal type is a template. v1 has `course`, `book`, and `habit`. Users and Claude can add custom templates.
3. **Widgets.** Each template defines its own home-screen widgets. A composite widget combines tiles from several goals.
4. **Reminders that push.** Escalating alarms and distraction nudges make the user start the work.
5. **Google Drive.** The user can back up the app data to Google Drive.

The app opens the content of each task directly. It plays the next lecture at the saved position. It opens a PDF at today's page.

## 2. Goals and non-goals

### 2.1 Goals

- Render any goal from a JSON document without an app update, if the goal uses known components and progress engines.
- Let Claude generate valid plans reliably.
- Open the content of the next task with one tap, from the app, a widget, a notification, or an alarm.
- Make the user start the work, with alarms and nudges that the user controls.
- Work fully offline. Google Drive is optional.

### 2.2 Non-goals (v1)

- iOS support.
- Plan creation inside the app. Claude creates plans.
- Arbitrary code in JSON. The app never runs code from a document.
- HTML or WebView rendering.
- Social features, accounts, or a backend server.
- Multi-device live sync. v1 supports backup and restore only. See section 13.

## 3. User flow

1. The user asks Claude: "Make a plan to finish Stanford CS229 by 31 December."
2. The `getonit-planner` skill generates a goal document.
3. The user sends the document to the phone. The user can use the Android share sheet, open a file, or paste text.
4. The app validates the document and shows a preview. The preview includes the proposed reminders and alarms.
5. The user confirms. The app saves the goal and schedules the reminders.
6. The user tracks progress in the app, in widgets, and through reminders.
7. (Phase 2) The user exports progress. Claude reads it and creates a new plan.

## 4. Architecture

### 4.1 Overview

```
                    ┌───────────────────────────────────────────────┐
 Claude skill ─JSON─▶  Import & Validation                          │
                    │        │                                      │
                    │        ▼                                      │
                    │  Template Registry ◀── built-in + custom      │
                    │        │                                      │
                    │        ▼                                      │
                    │  Goal Store (drift) ──▶ Event Log             │
                    │        │                   │                  │
                    │        ▼                   ▼                  │
                    │  Progress Engines ──▶ state (computed)        │
                    │        │                                      │
                    │        ▼                                      │
                    │  Binding Resolver (template + data + state)   │
                    │        │                                      │
                    │  ┌─────┼──────────────┬──────────────┐        │
                    │  ▼     ▼              ▼              ▼        │
                    │ Screen Widget       Nudge          Alarm      │
                    │ renderer surfaces   surfaces       surfaces   │
                    │  │     │              │              │        │
                    │  └─────┴──────┬───────┴──────────────┘        │
                    │               ▼                               │
                    │         Action Router ──▶ handlers            │
                    └───────────────────────────────────────────────┘
                                    │
                         Google Drive backup (optional)
```

### 4.2 Layers and extension points

Each layer is an extension point. A new feature in one layer does not change the other layers.

| Layer | Purpose | How to extend |
|---|---|---|
| Components | Native Flutter building blocks | Register a new component builder (app update) |
| Templates | UI trees with bindings, for each surface | Import a template document (no app update) |
| Goals | A template reference, data, and local progress | Import a goal document |
| Progress engines | Compute `state` from `data` and events | Register a new engine (app update) |
| Actions | Things that the UI can trigger | Register a new action handler (app update) |
| Surfaces | Places where a template renders | Add a new surface renderer (app update) |

### 4.3 Flutter project structure

```
lib/
  app/                 app shell, routing, theme
  core/
    schema/            document models, JSON Schema validation
    binding/           {{path}} resolver
    actions/           action router and handlers
    events/            event log
  engines/             progress engines (video_series, page_range, ...)
  render/
    components/        one file per component builder
    renderer.dart      type → builder registry, fallback handling
  surfaces/
    screen/            goal screens, Today screen
    widgets/           home_widget bridge, widget tree export
    nudges/            unlock and usage nudges
    alarms/            alarm scheduling and alarm screens
  features/
    import/            share intent, file open, paste, preview, diff
    player/            YouTube player
    reader/            PDF reader
    drive/             Google Drive backup
  data/                drift database, DAOs
android/
  app/src/main/kotlin/app/getonit/
    widget/            Glance renderer
    alarm/             strict alarm activity
    nudge/             foreground service, usage checks
```

### 4.4 Technology choices

| Area | Choice | Reason |
|---|---|---|
| UI framework | Flutter (stable channel) | One codebase for the app UI |
| State | `riverpod` | Testable. Works well with database streams. |
| Database | `drift` (SQLite) | Relational data, streams, and migrations |
| Schema validation | `json_schema` | Validates documents against JSON Schema 2020-12 |
| YouTube | `youtube_player_iframe` | Official embedded player. Reports the position. |
| PDF | `pdfrx` | Fast. Opens a page directly. Renders a page to an image. |
| Widgets | `home_widget` + Jetpack Glance (Kotlin) | Native widgets with real buttons |
| Notifications | `flutter_local_notifications` | Levels 1 and 2 reminders, nudges |
| Alarms | `alarm` package + native Kotlin activity | Full-screen alarms with sound |
| Background work | `workmanager` | Daily reset, widget refresh, backup |
| Google sign-in | `google_sign_in` | Drive authorization |
| Drive API | `googleapis` (Drive v3) | File operations |
| Share intent | `receive_sharing_intent` | Receive JSON from other apps |

## 5. Documents

### 5.1 Document kinds

All documents are JSON. Each document has a `kind` and a `schemaVersion`.

| Kind | Purpose | Who creates it |
|---|---|---|
| `goal` | One goal: a template reference and data | Claude |
| `template` | A UI template, a data schema, and a progress engine | Built-in, Claude, or users |
| `dashboard` | A composite widget layout | The app editor or Claude (phase 2) |
| `bundle` | Several documents in one file | Claude |

### 5.2 Common fields

```json
{
  "kind": "goal",
  "schemaVersion": "1.0",
  "id": "stanford-cs229-2026"
}
```

Rules:

- `id` is stable. A new version of the same goal has the same `id`. The app merges by `id`.
- `id` uses lowercase letters, digits, and hyphens. The maximum length is 64.
- `schemaVersion` uses `MAJOR.MINOR`. The app accepts a newer MINOR version and ignores unknown fields. The app rejects a newer MAJOR version and asks the user to update the app.

### 5.3 Goal document

```json
{
  "kind": "goal",
  "schemaVersion": "1.0",
  "id": "stanford-cs229-2026",
  "template": "course@1",
  "title": "Stanford CS229: Machine Learning",
  "accent": "#e0573f",
  "icon": "🎓",
  "startDate": "2026-10-21",
  "deadline": "2026-12-31",
  "schedule": { "days": ["mon", "wed", "fri"] },
  "reminders": { "preset": "firm", "time": "19:00" },
  "nudges": { "suggestedApps": ["com.instagram.android"] },
  "data": { }
}
```

| Field | Required | Description |
|---|---|---|
| `template` | Yes | `<templateId>@<major>`. The app selects the newest installed version with that major version. |
| `title` | Yes | The display name |
| `accent` | No | A hex color. If it is missing, the app uses the Material You color. |
| `icon` | No | An emoji or a built-in icon name |
| `startDate`, `deadline` | No | ISO dates. The progress engine uses them for the pace. |
| `schedule.days` | No | The days for work. The default is every day. |
| `reminders` | No | A proposal only. See section 11. |
| `nudges` | No | A proposal only. See section 12. |
| `data` | Yes | Template-specific data. The template's `dataSchema` validates it. |

### 5.4 Template document

```json
{
  "kind": "template",
  "schemaVersion": "1.0",
  "id": "book",
  "version": "1.0.0",
  "title": "Book Read",
  "engine": "page_range",
  "dataSchema": { "$comment": "JSON Schema for goal.data" },
  "surfaces": {
    "screen":    { "type": "column", "children": [] },
    "tile":      { "type": "card", "child": {} },
    "tile_wide": { "type": "card", "child": {} },
    "widget": {
      "small":  { "type": "card", "child": {} },
      "medium": { "type": "card", "child": {} },
      "large":  { "type": "card", "child": {} }
    },
    "nudge": { "title": "{{goal.title}}", "body": "...", "actions": [] },
    "alarm": { "type": "column", "children": [] }
  }
}
```

Rules:

- `engine` names a built-in progress engine. See section 7.
- `version` uses semantic versioning. A goal refers to the major version only.
- The template must define `screen`. All other surfaces are optional. If a surface is missing, the app uses a default for the engine.
- A goal can appear in a composite widget only if its template defines `tile` or `tile_wide`.

### 5.5 Bundle document

```json
{
  "kind": "bundle",
  "schemaVersion": "1.0",
  "documents": [
    { "kind": "template", "...": "..." },
    { "kind": "goal", "...": "..." }
  ]
}
```

The app imports the templates first, then the goals.

## 6. Rendering

### 6.1 Render scope

Every template renders with one scope object:

| Key | Source | Example |
|---|---|---|
| `goal` | Common goal fields | `{{goal.title}}`, `{{goal.deadline}}` |
| `data` | `goal.data`, from Claude | `{{data.pages.end}}` |
| `state` | Computed by the progress engine | `{{state.today.label}}` |
| `app` | App values | `{{app.todayLabel}}`, `{{app.isDarkMode}}` |
| Loop variables | The `as` name of a `list` | `{{it.title}}` |

### 6.2 Bindings

- A binding is `{{path}}`. A path is a dot-separated key list, for example `state.next.title`. Array indexes use numbers, for example `data.items.0.title`.
- If a string is exactly one binding, the result is the raw value. The value can be a number, a boolean, an array, or an object.
- If a string contains text and bindings, the result is a string.
- A missing path resolves to `null` in a raw binding and to an empty string in a text binding.
- **Bindings contain no expressions.** There is no math, no logic, and no function call. The progress engine calculates all derived values, such as percentages, labels, and today's pages.

**Reason:** Path-only bindings are safe, simple to implement twice (Dart and Kotlin), and easy for Claude to generate correctly.

### 6.3 Conditional display

Every node can have a `visible` property. The value is a binding to a boolean, for example `"visible": "{{state.hasNext}}"`. If the value is false or null, the renderer skips the node.

### 6.4 Node format

```json
{
  "type": "button",
  "id": "resume",
  "visible": "{{state.hasNext}}",
  "expand": true,
  "label": "Resume",
  "action": { "type": "open_video", "params": { "videoId": "{{state.next.videoId}}" } },
  "fallback": { "type": "text", "value": "Update the app" }
}
```

| Common property | Description |
|---|---|
| `type` | Required. The component name. |
| `id` | Optional. Used for tests and analytics. |
| `visible` | Optional. See section 6.3. |
| `expand` | Optional. In a `row` or `column`, the node takes the free space. |
| `fallback` | Optional. The renderer uses this node if it does not know `type`. |

### 6.5 Component catalog (v1)

**Layout**

| Component | Properties |
|---|---|
| `column` | `children`, `gap`, `align` (`start`, `center`, `end`, `stretch`) |
| `row` | `children`, `gap`, `align` (`center`, `top`, `between`). A document cannot know the screen width. So in a row, `text`, `column`, `row`, `stat`, `badge`, `list`, and `section` children can shrink and wrap. Controls keep their natural size. |
| `card` | `child`, `style` (`elevated`, `tonal`, `outlined`, `tile`), `accent`, `action` |
| `grid` | `children`, `columns`, `gap`. A child can have `span`. |
| `list` | `items` (binding to an array), `as`, `item` (a node), `maxItems` |
| `section` | `title`, `child`, `collapsible` |
| `tabs` | `tabs` (array of `{ label, child }`) |
| `divider` | — |
| `spacer` | `size` |

**Display**

| Component | Properties |
|---|---|
| `text` | `value`, `style` (`display`, `title`, `subtitle`, `body`, `caption`, `label`), `maxLines` |
| `icon` | `name`, `box` |
| `image` | `src` (https URL or app asset), `width`, `height`, `fit` |
| `badge` | `label`, `tone` (`success`, `warning`, `danger`, `neutral`) |
| `stat` | `value`, `label` |
| `progress_bar` | `value` (0–1) |
| `progress_ring` | `value` (0–1), `size`, `stroke`, `label`, `sublabel` |
| `week_dots` | `days` (array of `{ d, s }`; `s` is `done`, `today`, `rest`, or empty) |
| `heatmap` | `cells` (array of `{ date, level }`), `weeks` |
| `media` | `kind` (`video`, `pdf_page`), `width`, `height`, plus `videoId`/`timestamp`/`progress` or `documentId`/`page` |

**Input**

| Component | Properties |
|---|---|
| `button` | `label`, `icon`, `variant` (`filled`, `tonal`, `text`), `full`, `action` |
| `checklist_item` | `label`, `sublabel`, `icon`, `checked`, `action` |
| `counter` | `increment`, `decrement` (actions) |
| `timer` | `goalId`, `targetMinutes` |
| `number_input` | `label`, `value`, `action` (the action receives the number as `params.value`) |

**Media (screen surface only)**

| Component | Properties |
|---|---|
| `video_player` | `provider` (`youtube`), `videoId`, `startSec`, `goalId`, `itemId` |
| `pdf_viewer` | `documentId`, `page`, `goalId` |

**Composition**

| Component | Properties |
|---|---|
| `embed` | `goalId`, `surface` (`tile` or `tile_wide`) |

### 6.6 Unknown components

1. If the node has a `fallback`, the renderer renders the fallback.
2. If not, the renderer shows a small "Unsupported component" placeholder in debug builds. In release builds, it renders nothing.
3. The renderer never throws an exception for an unknown component.

### 6.7 Capability manifest

The app publishes a capability manifest. The skill uses it to generate compatible documents. The app shows the manifest in Settings → About, and the user can copy it.

```json
{
  "app": "get-on-it",
  "appVersion": "1.0.0",
  "schemaVersions": ["1.0"],
  "components": ["column", "row", "card", "..."],
  "actions": ["open_video", "open_pdf_page", "..."],
  "engines": ["video_series", "page_range", "count", "check", "checklist"],
  "surfaces": ["screen", "tile", "tile_wide", "widget.small", "widget.medium", "widget.large", "nudge", "alarm"]
}
```

### 6.8 Reference renderer

`mockups/cards.html` contains a JavaScript reference renderer and sample cards. The Flutter and Kotlin renderers must produce the same structure for the same input. The sample documents in that file become conformance test fixtures. The mockups are older than this spec. For example, they use `data.title` instead of `goal.title`. Where the mockups and this spec differ, this spec is correct.

## 7. Progress engines

### 7.1 Purpose

A progress engine reads `goal`, `data`, and the event log. It returns the `state` object. Templates select one engine. A new template that reuses an engine needs no app update.

```dart
abstract class ProgressEngine {
  String get id;
  Map<String, Object?> computeState(Goal goal, List<Event> events, DateTime now);
  bool isTodayComplete(Goal goal, List<Event> events, DateTime now);
}
```

### 7.2 Common state keys

All engines return these keys:

| Key | Type | Description |
|---|---|---|
| `progress` | number 0–1 | Overall progress |
| `pctLabel` | string | For example `"42%"` |
| `progressLabel` | string | For example `"7 of 20 lectures"` |
| `todayComplete` | boolean | True when today's target is met |
| `todayPending` | boolean | The opposite of `todayComplete`. Bindings cannot negate a value, so templates need both. |
| `isComplete` | boolean | True when `progress` is 1 |
| `streak` | number | Consecutive completed scheduled days |
| `streakLabel` | string | For example `"9 days"` |
| `pace.status` | string | `ahead`, `on_track`, `behind`, or `none` |
| `pace.label`, `pace.tone` | string | For example `"2 behind"`, `"warning"` |
| `deadlineLabel` | string | For example `"71 days"` |
| `week` | array | Data for `week_dots` |
| `heatmap` | array | Data for `heatmap` |

### 7.3 `video_series` engine (course template)

**Data**

```json
{
  "provider": "youtube",
  "playlistUrl": "https://www.youtube.com/playlist?list=...",
  "completionThreshold": 0.9,
  "items": [
    { "id": "lec-01", "kind": "video", "title": "Lecture 1: Introduction",
      "videoId": "...", "durationSec": 4500, "week": 1 },
    { "id": "pset-01", "kind": "task", "title": "Problem Set 1",
      "url": "https://...", "week": 2 }
  ],
  "milestones": [ { "id": "m1", "title": "Supervised learning", "afterItem": "lec-08" } ]
}
```

**Rules**

- A video is done when the watched position reaches `completionThreshold` (default 0.9) of `durationSec`, or when the user marks it done.
- A task is done when the user marks it done.
- `progress` is the watched seconds divided by the total seconds. Tasks count as a fixed weight (default 15 minutes each).
- The pace compares `progress` with the linear target between `startDate` and `deadline`, on scheduled days only.
- Today is complete when the user watches at least `dailyTargetMinutes` (default 30) or finishes one item.

**Extra state:** `next` (`id`, `title`, `videoId`, `positionSec`, `positionLabel`, `remainingLabel`, `watched`), `hasNext`, `items` (with `done` and `watched`), `hoursLabel`, `lecturesLabel`, `paceText`.

### 7.4 `page_range` engine (book template)

**Data**

```json
{
  "book": { "title": "Atomic Habits", "author": "James Clear" },
  "source": { "kind": "local_file" },
  "pages": { "start": 1, "end": 320, "perDay": 2 }
}
```

`source.kind` is `local_file`, `drive_file`, `url`, or `physical`.

**Rules**

- If `goal.deadline` is set, the engine calculates the pages per day from the remaining pages and the remaining scheduled days. The deadline wins over `pages.perDay`.
- The PDF reader writes a `page_reached` event when the user views a page for 5 seconds or more.
- For `physical` books, the user enters the page number manually.
- Today is complete when the last page read reaches today's end page.

**Extra state:** `today` (`startPage`, `endPage`, `label`, `minutesLabel`), `lastPage`, `nextPage`, `perDay`, `finishLabel`, `needsFile` (true when the PDF link is missing), `canOpen`, `isPhysical`, `isUrl`.

### 7.5 `count` engine (habit template)

**Data:** `{ "unit": "glasses", "target": 8, "period": "day" }`. `period` is `day` or `week`.

**Rules:** the engine sums `count_delta` events in the period. Today is complete when the sum reaches the target.

**Extra state:** `count`, `target`, `label`.

### 7.6 `check` engine (habit template)

**Data:** `{ "avoid": false }`. If `avoid` is true, the habit is a "do not do" habit. A check means a slip.

**Extra state:** `checked`, `cleanDays` (for `avoid` habits).

### 7.7 `checklist` engine

**Data:** `{ "steps": [ { "id": "s1", "title": "Stretch" } ], "resets": "daily" }`. `resets` is `daily` or `never`.

**Extra state:** `steps` (with `done`), `doneCount`.

### 7.7a `by_mode` (engine selection)

A template can set `"engine": "by_mode"`. Then each goal selects the engine with `data.mode`. The `habit` template uses this, so one template covers count, check, and checklist habits.

These engines also return mode flags (`isCount`, `isCheck`, `isChecklist`). A template uses them with `visible` to show the correct control.

### 7.8 Events

The app stores progress only as events. The engines compute `state` from the events. Events are never edited. A correction is a new event.

| Event | Fields | Written by |
|---|---|---|
| `item_position` | `item`, `sec` | YouTube player (every 15 s and on pause) |
| `item_done` | `item`, `done` (bool) | Player, mark-done action |
| `page_reached` | `page` | PDF reader, manual page entry |
| `count_delta` | `delta` | Counter |
| `check` | `checked` (bool) | Check habit |
| `step_done` | `step`, `done` (bool) | Checklist |
| `timer_session` | `minutes` | Timer |
| `day_skipped` | `date`, `reason` | Emergency exit, freeze day |
| `reminder_outcome` | `level`, `outcome` | Alarm system |

Common fields: `id` (UUID), `t` (UTC timestamp), `tz` (UTC offset in minutes at that moment), `goal`, `device`.

### 7.9 State calculation

**Rule:** the app stores only events. It never stores a calculated value such as "progress = 42%". It calculates the state from the events each time.

**Pipeline**

1. A user action writes an event.
2. The database stream reports the new event for that goal.
3. The goal's engine reads the goal, its data, its linked files, and all its events. It returns a new state.
4. The renderer fills the template bindings with the state.
5. The same state goes to every surface (screens, widgets, reminders).

The engine is a pure function. The same input always gives the same output.

**Why events**

- A re-import keeps progress, because events refer to item IDs.
- A change to the plan (for example, a new deadline) recalculates everything.
- Streaks, heatmaps, and a re-plan with Claude use the same history.
- Undo is a new event. Nothing is overwritten.
- A later multi-device sync only needs to combine event lists.

**Days**

- A day is a whole day in the user's local time zone. The engine stores days as day numbers.
- **My day starts at** (Settings, 00:00–06:00) moves the day boundary. With 04:00, work at 01:00 counts for the day before.
- Each event stores its UTC time and the UTC offset at that moment. A trip to another time zone does not move old events to another day.

**Fixed daily targets**

Today's target comes from the progress **before** today. For example, if the user had read to page 44 before today, today's pages are 45–46. When the user reads page 45, the target stays 45–46.

**Video positions**

- **Resume** uses the newest position.
- **Watched amount** and **done** use the highest position. Re-watching a part never lowers progress.
- **Watch time today** counts forward movement that is not faster than the clock. A seek forward does not count.

**Streak**

The engine goes back day by day:
- A complete scheduled day adds 1.
- A day that is not scheduled, or a `day_skipped` day, is passed over. It does not break the streak.
- A missed scheduled day ends the streak.
- Today adds 1 when it is complete. Today never breaks the streak while it is in progress.

**Pace**

```
expected = scheduled days passed ÷ all scheduled days from start to deadline
actual   = progress
```

The tolerance is one day of work. The result is `ahead`, `on_track`, or `behind` with the number of days, for example "2 days behind". The `page_range` engine also raises the daily target when the goal is behind, so the user can still finish by the deadline.

The start of a goal is `startDate`. If the goal has no `startDate`, the start is the day of the first import.

**When the state is recalculated**

| Trigger | Scope |
|---|---|
| A new event | That goal |
| A new goal version (import) | That goal |
| A linked file | That goal |
| A new day (a timer at the day boundary, and when the app resumes) | All goals |
| A change to **My day starts at** | All goals |

**Performance:** a full recalculation from all events takes milliseconds, also for a year of events. Snapshots are not necessary in v1.

## 8. Actions

### 8.1 Format

```json
{ "type": "open_pdf_page", "params": { "documentId": "{{goal.id}}", "page": "{{state.today.startPage}}" } }
```

The renderer resolves the bindings in `params` when the user triggers the action. The action router validates `params` and calls the handler.

### 8.2 Action catalog (v1)

| Action | Params | Result |
|---|---|---|
| `open_goal` | `goalId` | Opens the goal screen |
| `open_video` | `provider`, `videoId`, `startSec`, `goalId`, `itemId` | Opens the in-app player at the position |
| `open_external` | `url` | Opens the URL in an external app (for example the YouTube app) |
| `open_pdf_page` | `documentId`, `page` | Opens the PDF reader at the page. Asks for the file if the link is missing. |
| `link_file` | `goalId`, `documentId` | Lets the user select a PDF. The app copies it into the app's private storage and links it to the goal. |
| `mark_done` | `goalId`, `itemId` or `scope: "today"` | Writes `item_done`, or marks today complete |
| `toggle_done` | `goalId`, `stepId` or `itemId` (optional) | Toggles a check, a checklist step, or a course item |
| `log_progress` | `goalId`, `delta` or `value` | Writes `count_delta` or `page_reached` |
| `start_timer` | `goalId`, `minutes` | Starts a timer session (not in the first build) |
| `snooze_reminder` | `goalId`, `minutes` | Snoozes the current reminder or nudge (not in the first build) |
| `notify` | `message` | Shows a short message |

### 8.3 Action rules

- `open_external` accepts only `https` URLs and the `vnd.youtube:` scheme.
- An action with an unknown `type` does nothing and writes a debug log entry.
- Widget actions run in a background Dart callback through `home_widget`. Open actions start the app with a deep link.

### 8.4 Deep links

| Link | Target |
|---|---|
| `getonit://goal/<goalId>` | Goal screen |
| `getonit://goal/<goalId>/video/<itemId>?t=<sec>` | Player |
| `getonit://goal/<goalId>/page/<page>` | PDF reader |
| `getonit://today` | Today screen |
| `getonit://import` | Import screen with the clipboard content |

## 9. Templates (v1)

### 9.1 `course@1`

- **Engine:** `video_series`.
- **Screen:** Up Next card, progress detail (ring, statistics, week dots, pace), item list grouped by week, milestones.
- **Player screen:** the YouTube player, notes with timestamps, "Mark done", "Open in YouTube".
- **Tile:** progress ring and the next lecture.
- **Widgets:** small (ring and pace), medium (Up Next with a "Resume" button), large (Up Next and the next 3 items).
- **Nudge:** "Lecture 8 is waiting. 46 minutes left."
- **Alarm:** next lecture title, "Get on it →" (opens the player).

### 9.2 `book@1`

- **Engine:** `page_range`.
- **Screen:** Today's Pages card, progress bar, streak, expected finish date, "Change PDF".
- **Reader screen:** the PDF reader at today's start page, a "Today: p. 45–46" banner, auto-save of the last page.
- **Tile:** page thumbnail and today's pages.
- **Widgets:** small (ring and streak), medium (thumbnail, today's pages, "Done" button).
- **Nudge:** "2 pages of Atomic Habits. About 4 minutes."
- **Alarm:** book title and pages, "Get on it →" (opens the reader).

### 9.3 `habit@1`

- **Engine:** `count`, `check`, or `checklist`. The goal selects the engine with `data.mode`.
- **Screen:** the control for the mode (counter, check button, or checklist), streak, heatmap.
- **Tile:** the control in compact form.
- **Widgets:** small and medium.

The mockup page (`mockups/cards.html`) shows samples of these surfaces.

## 10. Home-screen widgets

### 10.1 Approach

The widgets use a hybrid approach:

- **Jetpack Glance (Kotlin)** renders layout, text, buttons, and checkboxes natively.
- **Small images** show complex visuals: progress rings, heatmaps, and PDF thumbnails. Flutter renders these images.

**Reason:** Glance gives real buttons with one action for each element, sharp text, and dynamic colors. An image-only widget has only one tap action.

### 10.2 Data flow

1. A goal changes (a new event, a new day, or a new import).
2. Flutter resolves the widget surface tree with the current scope. The result has no bindings.
3. Flutter renders the image components to PNG files in the app's storage.
4. Flutter saves the resolved tree as JSON with `home_widget` and requests a widget update.
5. The Glance renderer reads the tree and maps each node to a composable.
6. A tap on a button calls `actionRunCallback`. The callback sends the action to a Dart background callback, or opens a deep link.
7. The Dart callback writes the event, and the flow starts again at step 1.

### 10.3 Glance component subset

| JSON component | Glance mapping |
|---|---|
| `column`, `row` | `Column`, `Row` |
| `card` | `Box` with background and corner radius |
| `text` | `Text` |
| `button` | `Button`, or a clickable `Box` |
| `checklist_item` | `CheckBox` with label |
| `list` | `LazyColumn` |
| `progress_bar` | `LinearProgressIndicator` |
| `progress_ring`, `heatmap`, `media` | `Image` from a PNG file |
| `badge`, `icon`, `divider`, `stat` | `Box`, `Text`, `Image` |
| `grid` | Nested `Row`s and `Column`s |
| `embed` | Resolved by Flutter before export |

The import validator rejects widget surfaces that use other components, for example `video_player`.

### 10.4 Sizes

The widget uses `SizeMode.Responsive`. Android selects the `small`, `medium`, or `large` tree for the current widget size.

### 10.5 Composite widgets

A composite widget shows tiles from several goals in one large widget.

```json
{
  "kind": "dashboard",
  "schemaVersion": "1.0",
  "id": "today-dashboard",
  "mode": "manual",
  "layout": { "type": "grid", "columns": 2, "gap": 8, "children": [
    { "type": "embed", "goalId": "cs229", "surface": "tile" },
    { "type": "embed", "goalId": "atomic-habits", "surface": "tile" },
    { "type": "embed", "goalId": "water", "surface": "tile_wide", "span": 2 }
  ]}
}
```

Rules:

- Each embedded tile renders with its own goal's scope. Each tile keeps its own actions.
- `mode` is `manual` (the user selects goals) or `auto_today` (the app fills the slots with today's unfinished goals, in priority order).
- If a goal is deleted, the tile shows "Goal removed".
- When the widget gets smaller, the app removes the last tiles first.
- v1 provides an in-app editor for `manual` dashboards with preset layouts: 2×2, 1 wide + 2 square, and 4 wide rows.

### 10.5a As built

- **Today** widget (`TodayWidgetReceiver`): a header, then each goal's `tile_wide` surface. Open goals come first.
- **Goal** widget (`GoalWidgetReceiver`): one goal, selected in a picker when the user adds the widget. It uses `widget.small` or `tile` when narrow, and `widget.medium` or `tile_wide` when wide.
- Flutter writes the resolved trees with `home_widget`: `today`, `goal:<id>:small`, `goal:<id>:medium`, and `goals`.
- Buttons with `mark_done`, `toggle_done`, or `log_progress` run a Dart callback in the background (`widgetBackgroundCallback`). The callback writes the event and redraws the widgets. Other actions open the app with `getonit://action?json=<action>`.
- The database is shared across isolates, so the app's screens see widget taps at once.

### 10.6 Update policy

- The app updates the widgets after each event.
- A `workmanager` job updates the widgets after midnight, for the new day.
- The app does not depend on the Android periodic update interval.

## 11. Reminders and alarms

### 11.1 Levels

| Level | Behavior | Dismiss |
|---|---|---|
| `notification` | A normal notification | Swipe |
| `sticky` | An ongoing notification | "Done" or "Snooze" |
| `alarm` | A full-screen alarm with sound and vibration | "Get on it →" or "Snooze" |
| `strict_alarm` | A full-screen alarm that rings until the user completes a challenge | The challenge, or the emergency exit |

### 11.2 Escalation ladder

```json
"reminders": {
  "days": ["mon", "wed", "fri"],
  "ladder": [
    { "at": "19:00", "level": "notification" },
    { "at": "19:30", "level": "sticky" },
    { "at": "20:00", "level": "alarm", "maxSnoozes": 2, "snoozeMin": 10 },
    { "at": "20:30", "level": "strict_alarm",
      "dismiss": { "type": "do_task", "minProgress": { "minutes": 5 } } }
  ],
  "stopWhen": "today_complete"
}
```

The ladder stops when the engine reports `todayComplete`.

### 11.3 Presets

| Preset | Ladder |
|---|---|
| `gentle` | Notification at the reminder time |
| `firm` | Notification, sticky after 30 min, alarm after 60 min |
| `strict` | Firm, plus a strict alarm after 90 min with `do_task` |

A goal document can propose a preset or a full ladder.

### 11.4 Dismiss challenges (strict alarm)

| Challenge | Behavior |
|---|---|
| `do_task` | The alarm stops when the engine records the required progress, for example 5 minutes of video or 2 pages. The alarm screen has one button: "Get on it →". It opens the content. The alarm sound stops while the content is open. If the user leaves without progress, the alarm rings again after 3 minutes. |
| `start_task` | The alarm stops when the user opens the content. It rings again after 10 minutes if there is no progress. |

v1 supports `do_task` and `start_task` only.

### 11.5 Safety rules

These rules are mandatory. A document cannot change them.

- **User approval.** Imported reminders are proposals. The import preview shows them. The user must turn them on.
- **Emergency exit.** Every strict alarm has an exit: hold a button for 10 seconds, then confirm "Skip today". The app writes a `day_skipped` event.
- **Quiet hours.** The default is 23:00–07:00. No alarms ring in quiet hours.
- **Do Not Disturb.** The app respects DND by default. The user can allow an exception.
- **Daily limit.** No more than 6 alarm-level reminders for each day, across all goals.
- **Pause all.** One switch pauses all reminders for 1 day, 3 days, or 1 week.
- **Volume.** The volume rises slowly to the user's maximum.

### 11.6 Android implementation

| Topic | Implementation |
|---|---|
| Exact time | `AlarmManager.setAlarmClock`. Requires `SCHEDULE_EXACT_ALARM`. The app guides the user to the "Alarms & reminders" setting. Without it, the app uses inexact notifications. |
| Full-screen alarm | `USE_FULL_SCREEN_INTENT` with a native `StrictAlarmActivity` that shows over the lock screen. Without the permission, the app uses a heads-up notification with sound. |
| Strict alarm screen | Native Kotlin activity. It blocks the back button. It renders the template's `alarm` surface from a resolved tree. |
| Reboot | A `BOOT_COMPLETED` receiver schedules all reminders again. |
| Battery savers | The onboarding guides the user to turn off battery optimization for the app. |

## 12. Distraction nudges

### 12.1 Levels

| Level | Trigger | Permission |
|---|---|---|
| Unlock nudge | The user unlocks the phone, and a scheduled goal is not complete | Foreground service with a dynamic `ACTION_USER_PRESENT` receiver |
| Usage nudge | The user spends more than N minutes in a selected app | `PACKAGE_USAGE_STATS` (the user grants it in Settings) |

v1 implements both levels. An interrupt screen over other apps is out of scope for v1.

### 12.2 Rules

- The user selects the distracting apps in the app. A goal document can only suggest apps (`nudges.suggestedApps`).
- The default limit is 1 nudge for each 2 hours, and 4 for each day.
- No nudges in quiet hours, or when all of today's goals are complete.
- The nudge shows one small, specific action from the template's `nudge` surface, for example "Read p. 45–46".
- Each nudge has the actions "Get on it", "Snooze 1 h", and "Done today".

### 12.3 Usage check

A foreground service checks `UsageStatsManager` every 2 minutes while the screen is on. The service stops when the screen is off. The service type is `specialUse`, with a Play Console declaration.

## 13. Google Drive

### 13.1 Scope

The app uses the `drive.file` scope. The app can access only the files that it creates, and the files that the user selects with the Google Picker.

**Reason:** `drive.file` does not require Google's restricted-scope security assessment. Users also trust a narrow scope more.

### 13.2 Folder structure

```
Get On It/
  goals/        <goalId>.json
  templates/    <templateId>@<version>.json
  dashboards/   <dashboardId>.json
  events/       <deviceId>/<yyyy-mm>.jsonl
  notes/        <goalId>.json
  settings.json
```

### 13.3 v1: backup and restore

- The user connects Google Drive in Settings. Sign-in is optional.
- The app uploads changed files after a change (with a 60-second delay) and once each day.
- Restore: on a new phone, the user signs in and selects "Restore". The app downloads all files and rebuilds the database.
- Events use one file for each device and month. So a later multi-device sync can merge files without conflicts.

### 13.4 Phase 2: multi-device sync

- Each device reads the event files of all devices and applies new events in time order.
- For goals, templates, dashboards, and settings, the newest file wins.

### 13.5 PDFs on Drive

The user can select a PDF from Drive with the Google Picker. The app stores the Drive file ID. The app downloads the file to a local cache before it opens it. The app does not copy PDFs into the app folder.

### 13.6 Privacy

- **Disconnect** stops the backup.
- **Delete backup** deletes the app folder from Drive.
- Optional encryption with a user passphrase is a phase 2 feature.

## 14. Import

### 14.1 Channels

| Channel | Implementation |
|---|---|
| Share sheet | Intent filters for `text/plain` and `application/json` |
| Open file | Intent filter for `application/json` and the `.getonit.json` extension |
| Paste | "Paste plan" button on the Today screen |
| Drive | Open a file from the Drive app with "Open with → Get On It" |

### 14.2 Validation

1. Parse the JSON. If the text contains a fenced code block, the app extracts the JSON from it. Claude often wraps JSON in a code block.
2. Check `kind` and `schemaVersion`.
3. Validate the document against the JSON Schema for its kind.
4. For goals, validate `data` against the template's `dataSchema`.
5. Validate all template trees: known components, allowed components for each surface, depth ≤ 20, nodes ≤ 500.
6. Check URLs: only `https`.
7. Maximum document size: 1 MB.

Errors show a path and a short message, for example `data.items[3].videoId: required`. The user can copy the errors and give them to Claude for a fix.

### 14.3 Preview and merge

- **New goal:** the preview shows the title, the template, a summary (for example "20 lectures · 25 h · deadline 31 Dec"), and the proposed reminders.
- **Existing goal (same `id`):** the preview shows a diff, for example "2 lectures added, 1 renamed. Your progress stays." Events refer to item IDs, so progress stays.
- **Removed items:** the app keeps the events but hides the items.

## 15. Data model (drift)

| Table | Columns |
|---|---|
| `templates` | `id`, `version`, `json`, `source` (`builtin`, `imported`), `installedAt` |
| `goals` | `id`, `templateId`, `templateMajor`, `json`, `status` (`active`, `paused`, `done`, `archived`), `createdAt`, `updatedAt` |
| `events` | `id`, `goalId`, `type`, `payload`, `t`, `device` |
| `notes` | `id`, `goalId`, `itemId`, `positionSec`, `page`, `text`, `createdAt` |
| `files` | `goalId`, `documentId`, `kind` (`local_uri`, `drive_id`, `url`), `ref`, `cachedPath` |
| `reminders` | `goalId`, `ladderJson`, `enabled` |
| `nudge_rules` | `id`, `packageName`, `thresholdMin`, `enabled` |
| `dashboards` | `id`, `json`, `widgetId` |
| `settings` | `key`, `value` |

The app caches computed `state` in memory. It recomputes the state when a new event arrives for that goal.

## 16. Claude skill: `getonit-planner`

### 16.1 Contents

```
getonit-planner/
  SKILL.md                    instructions and rules
  schema/
    goal.schema.json
    template.schema.json
    dashboard.schema.json
    bundle.schema.json
  templates/                  copies of course@1, book@1, habit@1
  examples/
    course-cs229.getonit.json
    book-atomic-habits.getonit.json
    habit-water.getonit.json
    custom-template-bundle.getonit.json
  scripts/
    playlist_to_items.py      yt-dlp → items[] with videoId and duration
    validate.py               validates a document against the schemas
```

### 16.2 Rules in SKILL.md

- Select a built-in template if one fits. Make a custom template only if no built-in template fits.
- Use only the components, actions, and engines in the capability manifest.
- Use real video IDs and durations. Run `playlist_to_items.py` when network access is available. If it is not available, tell the user that the IDs need a check.
- Make a realistic pace. Include rest days.
- Propose a reminder preset. Do not propose a strict preset unless the user asks for it.
- Run `validate.py` before output.
- Output one JSON code block and a file named `<id>.getonit.json`.

### 16.3 Environments

| Environment | Playlist script | Output |
|---|---|---|
| Claude Code | Runs (network available) | Writes the file. The user can send it to the phone. |
| claude.ai | Depends on the code execution network settings | A file to download or a code block to copy |

## 17. Security and privacy

- Documents contain no executable code. Bindings are paths only.
- The app validates every document before it saves it.
- External links are `https` only.
- The app has no backend and no analytics in v1. All data stays on the device and, if the user chooses, in the user's Google Drive.
- Sensitive permissions (usage access, exact alarms, full-screen intent) are optional. The app explains each one before it asks.

## 18. Testing

| Test type | Scope |
|---|---|
| Unit | Binding resolver, each progress engine, action param validation, import validation |
| Golden | Each component, each built-in template surface, light and dark |
| Conformance | The sample documents from `mockups/cards.html`. The Dart resolver and the Kotlin renderer must produce the expected trees. |
| Integration | Import → render → action → event → state → widget update |
| Manual device | Alarms after reboot, Doze mode, battery savers (Samsung, Xiaomi), DND |

## 19. Delivery plan

| Phase | Content |
|---|---|
| **M1 — Core renderer** | Schema models, validation, binding resolver, component catalog, Today screen, paste import |
| **M2 — Templates** | `video_series` and `page_range` engines, YouTube player, PDF reader, course and book templates |
| **M3 — Habit and widgets** | `count`, `check`, `checklist` engines, habit template, Glance renderer, template widgets |
| **M4 — Composite widgets** | `embed`, `grid`, dashboard editor, `auto_today` mode |
| **M5 — Reminders** | Notification and sticky levels, alarms, strict alarm, presets, safety rules |
| **M6 — Nudges** | Unlock nudge, usage nudge, app selection |
| **M7 — Drive** | Sign-in, backup, restore, PDF from Drive |
| **M8 — Skill** | `getonit-planner` skill, schemas, examples, scripts |
| **Phase 2** | Multi-device sync, progress export and re-plan, encryption, dashboards from Claude, interrupt screen |

M8 can run in parallel with M2–M7, because it depends only on the schemas from M1.

### 19.1 Status (2026-10-21)

All milestones M1–M8 are built in PR #1. These parts differ from the plan or are not built:

| Item | Status |
|---|---|
| Widgets: `progress_ring` | Glance has no determinate ring. The widget shows the label over a short bar. Flutter does not render images for widgets. |
| Widgets: dashboard editor (§10.5 `manual` mode) | Not built. The **Today** widget uses `auto_today`. The **Goal** widget shows one goal that the user selects. |
| Widgets: `heatmap`, `image` | Not drawn in widgets. |
| Drive: real Google sign-in | Built, but not tested. It needs the OAuth clients in docs/drive.md. Tests use a fake Drive API. |
| Drive: PDF from Drive (§13.5) | Not built. Local PDFs are copied into app storage. |
| Reminders: Do Not Disturb exception (§11.5) | Not built. Android applies DND to the reminder channels. |
| Components `tabs`, `timer`, `video_player`, `pdf_viewer` (§6.5) | Not built. The player and the reader are screens, opened by actions. |
| Actions `start_timer`, `snooze_reminder` (§8.2) | Not built. Snooze is a notification button. |
| Course videos with embedding off | Built (`embeddable: false`). Such videos open on YouTube. All CS229 videos have embedding off. |

## 20. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Google Play rejects the alarm or usage permissions | Strict alarms or nudges are not available | Make the features optional. Write clear Play declarations. Keep inexact fallbacks. |
| Battery savers kill background work | Missed reminders and nudges | Onboarding guide. Exact alarms through `setAlarmClock`. |
| Claude generates invalid documents | Import fails | Strict schemas in the skill, `validate.py`, clear import errors that the user can give back to Claude |
| Wrong video IDs from Claude | Broken course items | Playlist script. The app checks the IDs with the player and marks broken items. |
| Two renderers (Dart and Kotlin) diverge | Widgets look different from the app | Flutter resolves bindings. Kotlin only maps components. Shared conformance fixtures. |
| YouTube embedded player limits | Some videos do not allow embedding | Fallback to `open_external` with manual completion |

## 21. Open decisions

The spec uses the defaults below. Each decision needs the owner's confirmation.

| # | Decision | Default in this spec |
|---|---|---|
| 1 | v1 templates | `course`, `book`, and `habit` |
| 2 | Course completion threshold | 90% watched |
| 3 | Book pace when both `perDay` and `deadline` exist | The deadline wins |
| 4 | Physical books | Supported with manual page entry |
| 5 | Strict alarm in v1 | Yes, with `do_task` and `start_task` only |
| 6 | Emergency exit on strict alarms | Always present |
| 7 | Distracting apps | The user selects them. Claude only suggests. |
| 8 | Composite widget builders in v1 | In-app editor and `auto_today` |
| 9 | Drive scope | `drive.file` with a visible folder |
| 10 | Drive in v1 | Backup and restore only. Sync in phase 2. |
| 11 | PDFs | Link only. The app does not copy PDFs to Drive. |
| 12 | Encryption | Phase 2 |
| 13 | Customer-visible identifiers | Package `app.getonit`, file extension `.getonit.json`, deep link scheme `getonit://`, Drive folder `Get On It/`. These identifiers are hard to change after release. |
| 14 | Name checks | Play Store, USPTO, and domain checks for "Get On It" are not done yet |
