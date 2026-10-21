# Custom look: screens and home-screen widgets

A goal can use a custom template instead of a built-in one. A custom template decides what the goal screen and the home-screen widgets show. Make one when the user asks for a special screen or widget, or when the goal needs more than a built-in template shows: links to resources, tips, several stats, extra buttons.

To use a custom template, reply with a bundle instead of a single goal:
{"kind": "bundle", "schemaVersion": "1.0", "documents": [ <template>, <goal> ]}

## The template document

- "kind": "template"
- "id": lowercase letters, digits and hyphens. Never "course", "book" or "habit".
- "version": "1.0.0". When you change an existing custom template, keep its "id" and raise the version, for example "1.0.1".
- "title", "description": short text.
- "engine": how progress is counted. The goal's "data" must have the fields that the engine reads:
  - "count": "unit" (text), "target" (integer), "period" ("day" or "week")
  - "check": nothing; "avoid": true for something to quit
  - "checklist": "steps": [{"id", "title"}]
  - "page_range": "book": {"title", "author"}, "pages": {"start", "end", "perDay"}, "source": {"kind": "physical" | "local_file" | "url", "url"}
  - "video_series": "items": [{"id", "kind": "video" | "task", "title", "videoId", "durationSec", "week", "url", "embeddable"}]
- "dataSchema": a JSON Schema for the goal's "data". List the engine fields and your own extra fields (for example "practiceUrl" or "tips"). The app checks the goal's "data" against it.
- "surfaces": the UI trees.
  - "screen" (required): the goal screen in the app.
  - "tile": the small home-screen widget (about 2×2 cells). Keep it to a ring or a big number and one short line.
  - "tile_wide": the medium home-screen widget (about 4×2 cells) and the goal's row in the "Today" widget. Use an icon, the title, one status line and one button.
  Always add "tile" and "tile_wide"; without them the widgets only show the title.

## Bindings

Text in "{{...}}" is filled in from the goal. Bindings are paths only: no math, no logic, no defaults.
- "{{goal.id}}", "{{goal.title}}", "{{goal.icon}}", "{{goal.accent}}", "{{goal.deadline}}", "{{goal.startDate}}"
- "{{data.<field>}}": any field of the goal's "data", for example "{{data.practiceUrl}}"
- "{{state.<key>}}": values the engine calculates (below)
- Inside a "list": "{{item.<field>}}", or another name set with "as"
- A binding that is the whole value keeps its type (number, list, true/false). Mixed text becomes text: "{{state.count}} of {{state.target}}".

State keys for every engine: progress (0 to 1), pctLabel ("42%"), progressLabel, isComplete, todayComplete, todayPending, todayScheduled, streak, streakLabel ("5 days"), pace.label and pace.tone ("On track" / "success"), deadlineLabel, todayLabel, week (for week_dots), heatmap (for heatmap).
- count: count, target, label ("3 / 8 glasses"), periodLabel ("today" or "this week")
- Labels already hold their unit and words. Write "{{state.label}}", not "{{state.label}} glasses".
- check: checked, avoid, cleanDays, cleanDaysLabel, buttonLabel
- checklist: steps (list of {id, title, done}), doneCount, label ("2 / 5")
- page_range: book.title, book.author, lastPage, nextPage, perDay, perDayLabel, today.label ("p. 45–46"), today.startPage, today.endPage, today.minutesLabel, today.pagesLeft, finishLabel, canOpen, needsFile, isPhysical
- video_series: items and next (each {id, title, kind, isVideo, isTask, videoId, embeddable, url, week, done, durationLabel, resumeLabel, remainingLabel, positionSec}), hasNext, doneCount, itemCount, lecturesLabel, hoursLabel, todayWatchedLabel, paceText

## Components

Every node is {"type": ..., ...}. Every node may have "visible": "{{...}}" (hidden when false, empty or missing) and "id". A child of a "row" may have "expand": true to take the free space.

Layout:
- column: children, gap, align ("start" | "center" | "end"; default stretch)
- row: children, gap, align ("between" | "top")
- card: child, style ("elevated" | "outlined" | "tonal" | "tile"), accent ("#rrggbb" or "{{goal.accent}}"), action (tap the whole card)
- grid: children, columns (1–6), gap; a child may have "span"
- list: items ("{{state.items}}" or "{{data.<list>}}"), item (one node, repeated), as, gap, maxItems
- section: title, child
- divider
- spacer: size

Display:
- text: value, style ("display" | "title" | "subtitle" | "body" | "caption" | "label"), maxLines
- icon: name (an emoji), box (true for a colored square)
- image: src ("https://..."), width, height
- badge: label, tone ("success" | "warning" | "danger" | "neutral")
- stat: value, label
- progress_bar: value (0 to 1)
- progress_ring: value (0 to 1), size, stroke, label, sublabel
- week_dots: days ("{{state.week}}")
- heatmap: cells ("{{state.heatmap}}")
- media: kind ("video" | "pdf_page"), videoId, progress, timestamp, page, width, height

Input:
- button: label, icon (an emoji), variant ("filled" | "tonal" | "outlined" | "text"), full (true for full width), action
- checklist_item: label, sublabel, icon, checked, action
- counter: increment (action), decrement (action)
- number_input: label, hint, buttonLabel, action (the app adds the typed number as params.value)

Composition:
- embed: goalId, surface ("tile" | "tile_wide"). Shows another goal inside this one.

## Actions

{"type": ..., "params": {...}}. Always pass "goalId": "{{goal.id}}".
- open_goal: goalId
- open_external: url ("https://..." or "{{data.<field>}}")
- open_video: goalId, itemId, videoId, startSec, embeddable
- open_pdf_page: goalId, page
- link_file: goalId (the user picks the PDF)
- mark_done: goalId, itemId (optional; without it the app completes today's work)
- toggle_done: goalId, plus stepId or itemId (without them it toggles a check habit)
- log_progress: goalId, and "delta" (count, for example 1 or -1) or "value" (page reached)
- notify: message (a short pop-up text)

## Widget rules

- Widgets cannot show heatmap, image, section or number_input. Use them only in "screen".
- In widgets, buttons with mark_done, toggle_done and log_progress work without opening the app. Other actions open the app.
- Give the widget card "action": open_goal, so a tap opens the goal.

## Good design

- Start the screen with a card that shows today's work and the main button. Then stats (streak, pace, progress), then week_dots, then the details (lists, links, tips).
- Show the pace with a badge: {"type": "badge", "visible": "{{state.pace.label}}", "label": "{{state.pace.label}}", "tone": "{{state.pace.tone}}"}.
- Use "visible" to show the right button for the state, for example a "Done for today" badge with "visible": "{{state.todayComplete}}".
- Put the goal's own links and tips in "data" and bind them. Links must start with "https://".
- At most 20 levels deep and 500 nodes.
