# getonit-planner

A Claude skill, packaged as a Claude Code plugin. It turns a goal into a plan file for the Get On It app.
Examples: "help me finish Stanford CS229 by December", "read Atomic Habits 2 pages a day", "drink 8 glasses of water".

For all install options (Claude Code plugin, skill folder, claude.ai, the Claude API, Codex, other tools), read [docs/skill-install.md](../docs/skill-install.md).

## Layout

```
skill/                          plugin root
  .claude-plugin/plugin.json    plugin manifest
  build-zip.sh                  builds dist/getonit-planner.zip for claude.ai
  skills/getonit-planner/       the skill
    SKILL.md                    instructions for Claude
    schema/                     JSON Schemas (2020-12) for goal, template, bundle
    templates/                  copies of the app's built-in templates
    examples/                   valid sample plans
    scripts/
      playlist_to_items.py      YouTube playlist -> course items
      validate.py               checks a plan file
      sync_schemas.py           copies the app templates and updates goal.schema.json
  tests/test_skill.py           unit tests
```

The marketplace file is `.claude-plugin/marketplace.json` at the repository root.

## Quick install

- Claude Code: `/plugin marketplace add kamrul1157024/get-on-it`, then `/plugin install getonit-planner@get-on-it`.
- Claude Code, skill only: copy `skill/skills/getonit-planner` to `~/.claude/skills/getonit-planner/`.
- claude.ai: run `skill/build-zip.sh`, then upload `skill/dist/getonit-planner.zip` in Settings > Features > Skills.

## Scripts

Run these from `skill/skills/getonit-planner/`.

Validate a plan. Install `jsonschema` for the full check. Without it, the script runs its own checks.

```bash
pip install jsonschema            # optional
python3 scripts/validate.py my-plan.getonit.json
python3 scripts/validate.py examples/*.json
python3 scripts/validate.py --no-jsonschema my-plan.getonit.json   # force the built-in checks
```

The exit code is 0 when the file is valid and 1 when it is not. Errors show a path, for example `data.items[3].videoId: required`.

Turn a YouTube playlist into course items. This needs `yt-dlp` (`pip install yt-dlp`) and network access.

```bash
python3 scripts/playlist_to_items.py "https://www.youtube.com/playlist?list=PLoROMvodv4rMiGQp3WXShtMGgzqpfVfbU" --per-week 2
python3 scripts/playlist_to_items.py "<playlist-url>" --check-embed --limit 2
```

- `--per-week N` sets how many videos go in each week (default 2).
- `--check-embed` opens each video and adds `"embeddable": false` when the owner turned off playback on other sites. It takes about 2 seconds per video.
- `--limit N` uses only the first N videos.

The JSON array goes to stdout. Notes go to stderr.

Keep the skill in sync after a built-in template changes in `mobile/assets/templates/`:

```bash
python3 scripts/sync_schemas.py          # copy templates and update schema/goal.schema.json
python3 scripts/sync_schemas.py --check  # exit 1 if something is out of date
```

## Tests

```bash
python3 -m unittest discover -s skill/tests -v
cd mobile && flutter test test/skill_examples_test.dart
```

The Flutter test checks that the app's own validator accepts every example. It also checks that `templates/` matches `mobile/assets/templates/`.
