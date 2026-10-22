#!/usr/bin/env python3
"""Keep the skill in sync with the app's built-in templates.

Usage:
  sync_schemas.py [--from DIR] [--check]

1. Copies DIR/*.json (default: the app's mobile/assets/templates when this
   skill sits inside the get-on-it repo) into the skill's templates/ folder.
2. Rewrites the generated parts of schema/goal.schema.json: one
   `$defs/data-<id>-<major>` per template (its dataSchema) and the
   `$defs/goal/allOf` if/then list that picks it by `template`.
3. Copies the app's UI reference and custom-template example (shared with
   the in-app prompts) to reference/ui.md and examples/.

With --check nothing is written. The exit code is 1 when something is out of
sync. Standard library only.
"""

import argparse
import json
import sys
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
TEMPLATES = SKILL / "templates"
GOAL_SCHEMA = SKILL / "schema" / "goal.schema.json"
APP_TEMPLATES = SKILL.parents[2] / "mobile" / "assets" / "templates"
APP_PROMPT = SKILL.parents[2] / "mobile" / "assets" / "prompt"
# The app's copy-paste prompts and the skill share one UI reference and one
# custom-template example; the app's files are the source.
SHARED = {
    "ui_reference.md": "reference/ui.md",
    "custom_example.json": "examples/custom-template-bundle.getonit.json",
}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def generated_parts(templates):
    defs, branches = {}, []
    for t in sorted(templates, key=lambda t: t["id"]):
        major = int(t["version"].split(".")[0])
        name = f"data-{t['id']}-{major}"
        defs[name] = t.get("dataSchema") or {"type": "object"}
        branches.append({
            "if": {"properties": {"template": {"const": f"{t['id']}@{major}"}}, "required": ["template"]},
            "then": {"properties": {"data": {"$ref": f"#/$defs/{name}"}}},
        })
    return defs, branches


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--from", dest="src", type=Path,
                   help=f"template folder (default: {APP_TEMPLATES} if it exists, else {TEMPLATES})")
    p.add_argument("--check", action="store_true", help="only report differences")
    args = p.parse_args(argv)

    src = args.src or (APP_TEMPLATES if APP_TEMPLATES.is_dir() else TEMPLATES)
    files = sorted(src.glob("*.json"))
    if not files:
        print(f"error: no templates in {src}", file=sys.stderr)
        return 2

    stale = []
    templates = []
    for f in files:
        text = f.read_text(encoding="utf-8")
        templates.append(json.loads(text))
        dest = TEMPLATES / f.name
        if src.resolve() != TEMPLATES.resolve():
            if not dest.exists() or load(dest) != json.loads(text):
                stale.append(f"templates/{f.name}")
                if not args.check:
                    dest.write_text(text, encoding="utf-8")

    if APP_PROMPT.is_dir():
        for name, rel in SHARED.items():
            text = (APP_PROMPT / name).read_text(encoding="utf-8")
            dest = SKILL / rel
            if not dest.exists() or dest.read_text(encoding="utf-8") != text:
                stale.append(rel)
                if not args.check:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_text(text, encoding="utf-8")

    schema = load(GOAL_SCHEMA)
    defs, branches = generated_parts(templates)
    all_defs = schema["$defs"]
    old = {k: v for k, v in all_defs.items() if k.startswith("data-")}
    if old != defs or all_defs["goal"].get("allOf") != branches:
        stale.append("schema/goal.schema.json")
        if not args.check:
            for k in old:
                del all_defs[k]
            all_defs.update(defs)
            all_defs["goal"]["allOf"] = branches
            GOAL_SCHEMA.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    if not stale:
        print(f"in sync with {src}")
        return 0
    verb = "out of sync" if args.check else "updated"
    for s in stale:
        print(f"{verb}: {s}")
    return 1 if args.check else 0


if __name__ == "__main__":
    sys.exit(main())
