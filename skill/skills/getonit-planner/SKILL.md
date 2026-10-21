---
name: getonit-planner
description: Makes a plan file for the Get On It Android app from a goal. Use it when the user wants to finish an online course or YouTube playlist, read a book or PDF by a date or at a set pace, or build or quit a daily habit (for example "help me finish Stanford CS229 by December", "read Atomic Habits 2 pages a day", "drink 8 glasses of water"), or when the user mentions Get On It or a .getonit.json file.
---

# Get On It planner

You turn the user's goal into one JSON document that the Get On It app imports.
The app checks the document strictly. A document that fails the check is useless to the user, so always validate it.

All paths below are relative to this skill's folder (the folder that holds this file).

## 1. Understand the goal

Find out, or make a sensible guess and say so:

- What: a course or playlist, a book, or a habit.
- When: a deadline, or a pace (for example 2 pages a day).
- Which days the user can work. Default to 5 or 6 days a week, so there are rest days.
- A good reminder time.

Ask at most one short question if something important is missing (for example the playlist link). Otherwise go ahead.

## 2. Pick a template

Use a built-in template whenever one fits. The app already has them.

| Goal | Template | Example |
|---|---|---|
| Videos, lectures, a course with tasks | `course@1` | `examples/course-cs229.getonit.json` |
| A book, a PDF, pages | `book@1` | `examples/book-deep-work-pdf.getonit.json` |
| Do something N times per day or week | `habit@1`, `mode: "count"` | `examples/habit-water.getonit.json` |
| A daily yes/no habit | `habit@1`, `mode: "check"` | |
| A habit to quit (a check means a slip) | `habit@1`, `mode: "check"`, `avoid: true` | `examples/habit-no-sugar.getonit.json` |
| A short list of steps | `habit@1`, `mode: "checklist"` | `examples/habit-morning-routine.getonit.json` |

The data rules for each template are in `templates/<name>.json` under `dataSchema`.

Make a custom template only when no built-in template fits (for example, the user wants a button that opens a practice website). Then output a bundle with the template and the goal, like `examples/custom-template-bundle.getonit.json`:

- Use engine `count`, `check`, `checklist`, `page_range`, or `video_series`.
- Use only these components: column, row, card, grid, list, section, divider, spacer, text, icon, image, badge, stat, progress_bar, progress_ring, week_dots, heatmap, media, button, checklist_item, counter, number_input, embed.
- Use only these actions: open_goal, open_video, open_external, open_pdf_page, link_file, mark_done, toggle_done, log_progress, notify.
- Surfaces: `screen` (required), `tile`, `tile_wide`.
- Bindings are paths only, like `{{state.count}}`, `{{data.practiceUrl}}`, `{{goal.title}}`. No math, no logic. Read the built-in templates to see which `state` keys each engine gives.
- Links must start with `https://`.
- Give the template its own id. Do not reuse `course`, `book`, or `habit`.

## 3. Fill in the goal

Common fields: `kind: "goal"`, `schemaVersion: "1.0"`, `id`, `template`, `title`, `data`. Optional: `accent` (`#rrggbb`), `icon` (an emoji), `startDate` and `deadline` (`YYYY-MM-DD`), `schedule.days` (`mon` … `sun`), `reminders`.

- `id`: lowercase letters, digits, and hyphens, 64 characters at most, for example `stanford-cs229`. Keep the same id when you update a plan. The app then merges it and keeps the user's progress.
- Set `startDate` to today when there is a deadline.

### Pace

- Make the plan realistic. Check that the work fits in the scheduled days before the deadline. If it does not fit, say so and suggest a later date or more days.
- Leave at least one rest day each week.
- Course: put about 2–3 hours of video per week for a busy adult (`week` on each item, `dailyTargetMinutes` of 20–45). Add tasks (`kind: "task"` with a `url`) for problem sets or projects.
- Book: with a deadline the app works out pages per day itself. Still set `pages.perDay` as a fallback. Count about 2 minutes per page. Use `source.kind`: `local_file` for a PDF on the phone (the app asks the user to pick the file), `drive_file`, `url` (needs `source.url`), or `physical` for a paper book.

### Videos

Use real video IDs and real durations. Never invent them.

When you can run code with network access:

```bash
python3 scripts/playlist_to_items.py "<playlist-url>" --per-week 2 --check-embed
```

It prints the `items` array. Use `--limit N` to try a few videos first. It needs `yt-dlp` (`pip install yt-dlp`).

- `--check-embed` sets `embeddable: false` on videos whose owner turned off playback on other sites. Keep that flag. The app then sends the user to YouTube for those videos. Many university channels, Stanford included, do this.
- If the script cannot run (no network or no yt-dlp), you may write the items yourself. Tell the user clearly that the video IDs and durations need a check, and suggest that they run the script on their computer.
- You can rename titles and change `week` values. Do not change `videoId` or `durationSec`.

### Reminders

Always propose reminders. The user turns them on in the app.

```json
"reminders": { "preset": "gentle", "time": "19:00" }
```

- `gentle`: one notification. Good for habits and light goals.
- `firm`: a notification, a sticky notification after 30 minutes, an alarm after 60 minutes. Good for goals with a deadline.
- `strict`: firm plus an alarm that rings until the user makes progress. Use it only when the user asks for it.

## 4. Validate

Save the document as `<id>.getonit.json` and run:

```bash
python3 scripts/validate.py <id>.getonit.json
```

Fix every error and run it again until it prints `OK`. Errors show a path, for example `data.items[3].videoId: required`. If the script says that `jsonschema` is missing, it still runs its own checks. You can install it with `pip install jsonschema` for a full check.

The user can also paste errors from the app back to you. Fix them the same way.

## 5. Answer

Give the user:

1. Two or three lines about the plan: what, how much per week, the finish date, and the reminder.
2. One JSON code block with the full document. Nothing else in code blocks.
3. The file `<id>.getonit.json`. In Claude Code, write it to the current folder. In claude.ai, attach it as a file.
4. How to get it onto the phone:
   - **Share:** send the file (or the copied text) to the phone, then use the Share button and pick Get On It.
   - **Open with:** open the `.getonit.json` file on the phone (from Downloads, Drive, or a chat app) and pick "Open with → Get On It".
   - **Paste:** copy the JSON code block, open Get On It, and tap "Paste plan" on the Today screen.

The app shows a preview before it saves anything. The user can check the plan and turn on the reminders there.
