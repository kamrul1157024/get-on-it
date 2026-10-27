#!/usr/bin/env python3
"""Validate a Get On It document before you give it to the user.

Usage:
  validate.py <file.json> [more files...] [--no-jsonschema]

Uses the `jsonschema` package with the schemas in ../schema when it is
installed. Without it (or with --no-jsonschema) a built-in check of the key
rules runs instead. Some checks run in both modes: tree size and depth, the
data of goals that use a custom template from the same bundle, unique item
ids, and date order.

Exit code 0 when every file is valid (warnings are allowed), 1 otherwise.
Errors print as `<json path>: <message>`, for example
`data.items[3].videoId: required`.
"""

import datetime
import json
import re
import sys
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
SCHEMA_DIR = SKILL / "schema"
TEMPLATE_DIR = SKILL / "templates"

MAX_BYTES = 1024 * 1024
MAX_DEPTH = 20
MAX_NODES = 500

ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
TEMPLATE_REF = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}@\d+$")
SCHEMA_VERSION = re.compile(r"^\d+\.\d+$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
FENCE = re.compile(r"```(?:json)?\s*\n([\s\S]*?)\n?```")

WEEKDAYS = {"mon", "tue", "wed", "thu", "fri", "sat", "sun"}
COMPONENTS = {
    "column", "row", "card", "grid", "list", "section", "more", "divider", "spacer",
    "text", "icon", "image", "badge", "stat", "progress_bar", "progress_ring",
    "week_dots", "heatmap", "media",
    "button", "checklist_item", "counter", "number_input",
    "embed",
}
ACTIONS = {"open_goal", "open_video", "open_external", "open_pdf_page", "link_file",
           "mark_done", "toggle_done", "log_progress", "notify"}
ENGINES = {"video_series", "page_range", "count", "check", "checklist", "by_mode"}
SURFACES = {"screen", "tile", "tile_wide"}
GOAL_FIELDS = {"kind", "schemaVersion", "id", "template", "title", "accent", "icon", "startDate",
               "deadline", "schedule", "reminders", "nudges", "data"}
TEMPLATE_FIELDS = {"kind", "schemaVersion", "id", "version", "title", "description", "engine",
                   "dataSchema", "surfaces"}
PRESETS = {"gentle", "firm", "strict"}
LEVELS = {"notification", "sticky", "alarm", "strict_alarm"}


class Issue:
    def __init__(self, path, message, warning=False):
        self.path, self.message, self.warning = path, message, warning

    def __str__(self):
        return f"{self.path or '(root)'}: {self.message}"


def join(path, key):
    if isinstance(key, int):
        return f"{path}[{key}]"
    return f"{path}.{key}" if path else str(key)


def fmt(parts):
    path = ""
    for p in parts:
        path = join(path, p)
    return path


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def builtin_templates():
    out = {}
    for f in sorted(TEMPLATE_DIR.glob("*.json")):
        t = load_json(f)
        out[f"{t['id']}@{t['version'].split('.')[0]}"] = t
    return out


def real_date(value):
    if not isinstance(value, str) or not DATE.match(value):
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


# ------------------------------------------------------------ mini JSON Schema
# Covers the keywords that template dataSchemas use. Used only without jsonschema.

def _is_type(value, t):
    if t == "object":
        return isinstance(value, dict)
    if t == "array":
        return isinstance(value, list)
    if t == "string":
        return isinstance(value, str)
    if t == "boolean":
        return isinstance(value, bool)
    if t == "null":
        return value is None
    if t == "integer":
        return (isinstance(value, int) and not isinstance(value, bool)) or (
            isinstance(value, float) and value.is_integer())
    if t == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return True


def mini_validate(schema, value, path, issues):
    if not isinstance(schema, dict):
        return
    before = len(issues)
    t = schema.get("type")
    if t is not None:
        types = t if isinstance(t, list) else [t]
        if not any(_is_type(value, x) for x in types):
            issues.append(Issue(path, f"must be of type {' or '.join(types)}"))
            return
    if "enum" in schema and value not in schema["enum"]:
        issues.append(Issue(path, "must be one of: " + ", ".join(json.dumps(v) for v in schema["enum"])))
    if "const" in schema and value != schema["const"]:
        issues.append(Issue(path, f"must be {json.dumps(schema['const'])}"))
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            issues.append(Issue(path, f"must have at least {schema['minLength']} characters"))
        if "pattern" in schema and not re.search(schema["pattern"], value):
            issues.append(Issue(path, f"{json.dumps(value)} does not match {schema['pattern']}"))
    if _is_type(value, "number"):
        if "minimum" in schema and value < schema["minimum"]:
            issues.append(Issue(path, f"must be {schema['minimum']} or more"))
        if "maximum" in schema and value > schema["maximum"]:
            issues.append(Issue(path, f"must be {schema['maximum']} or less"))
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            issues.append(Issue(path, f"needs at least {schema['minItems']} items"))
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            issues.append(Issue(path, "items must be unique"))
        if isinstance(schema.get("items"), dict):
            for i, v in enumerate(value):
                mini_validate(schema["items"], v, join(path, i), issues)
    if isinstance(value, dict):
        for name in schema.get("required", []):
            if name not in value:
                issues.append(Issue(join(path, name), "required"))
        props = schema.get("properties", {})
        for k, v in value.items():
            if k in props:
                mini_validate(props[k], v, join(path, k), issues)
            elif schema.get("additionalProperties") is False:
                issues.append(Issue(join(path, k), "unknown field"))
    for sub in schema.get("allOf", []):
        mini_validate(sub, value, path, issues)
    for key in ("anyOf", "oneOf"):
        if key in schema:
            ok = 0
            for sub in schema[key]:
                trial = []
                mini_validate(sub, value, path, trial)
                ok += not trial
            if ok == 0 or (key == "oneOf" and ok > 1):
                issues.append(Issue(path, f"does not match {key}"))
    if "if" in schema:
        trial = []
        mini_validate(schema["if"], value, path, trial)
        branch = schema.get("then") if not trial else schema.get("else")
        if branch is not None:
            mini_validate(branch, value, path, issues)
    return len(issues) == before


# ------------------------------------------------------------ jsonschema mode

def jsonschema_validator(kind):
    import jsonschema

    schemas = {p.name: load_json(p) for p in SCHEMA_DIR.glob("*.schema.json")}
    schema = schemas[f"{kind}.schema.json"]
    cls = jsonschema.Draft202012Validator
    try:
        from referencing import Registry, Resource

        registry = Registry().with_resources(
            (s["$id"], Resource.from_contents(s)) for s in schemas.values())
        return cls(schema, registry=registry)
    except ImportError:  # jsonschema < 4.18
        resolver = jsonschema.RefResolver.from_schema(schema, store={s["$id"]: s for s in schemas.values()})
        return cls(schema, resolver=resolver)


def convert_error(e, prefix=""):
    path = fmt(list(e.absolute_path))
    if prefix:
        path = prefix + ("." + path if path and not path.startswith("[") else path)
    v = e.validator
    if v == "required" and isinstance(e.instance, dict):
        return [Issue(join(path, n), "required") for n in e.validator_value if n not in e.instance]
    if v == "additionalProperties" and isinstance(e.instance, dict):
        allowed = set(e.schema.get("properties", {}))
        return [Issue(join(path, k), "unknown field (check the spelling)") for k in e.instance if k not in allowed]
    if v == "anyOf" and path.endswith("reminders"):
        return [Issue(path, 'needs "preset" and "time", or a "ladder"')]
    if v == "pattern":
        return [Issue(path, f"{json.dumps(e.instance)} does not match {e.validator_value}")]
    if v == "enum":
        return [Issue(path, f"{json.dumps(e.instance)} is not one of: "
                      + ", ".join(json.dumps(x) for x in e.validator_value))]
    return [Issue(path, e.message)]


def schema_issues(doc, kind):
    validator = jsonschema_validator(kind)
    out = []
    for e in sorted(validator.iter_errors(doc), key=lambda e: list(map(str, e.absolute_path))):
        out.extend(convert_error(e))
    return out


def data_issues(schema, data, path, use_jsonschema):
    issues = []
    if use_jsonschema:
        import jsonschema

        for e in jsonschema.Draft202012Validator(schema).iter_errors(data):
            issues.extend(convert_error(e, path))
    else:
        mini_validate(schema, data, path, issues)
    return issues


# ------------------------------------------------------------ fallback checks

def check_envelope(doc, p, issues, inherited_version=None):
    kind = doc.get("kind")
    if not isinstance(kind, str):
        issues.append(Issue(p + "kind", "required"))
    v = doc.get("schemaVersion", inherited_version)
    if not isinstance(v, str) or not SCHEMA_VERSION.match(v):
        issues.append(Issue(p + "schemaVersion", 'required, in the form MAJOR.MINOR, for example "1.0"'))
    elif int(v.split(".")[0]) != 1:
        issues.append(Issue(p + "schemaVersion", f"version {v} is not supported; use 1.0"))
    if kind != "bundle":
        i = doc.get("id")
        if not isinstance(i, str) or not ID.match(i):
            issues.append(Issue(p + "id", "required: lowercase letters, digits and hyphens, at most 64"))


def check_goal_fields(doc, p, issues):
    for k in doc:
        if k not in GOAL_FIELDS:
            issues.append(Issue(p + k, "unknown field (check the spelling)"))
    title = doc.get("title")
    if not isinstance(title, str) or not title.strip():
        issues.append(Issue(p + "title", "required"))
    ref = doc.get("template")
    if not isinstance(ref, str) or not TEMPLATE_REF.match(ref):
        issues.append(Issue(p + "template", "required, in the form <templateId>@<major>, for example course@1"))
    accent = doc.get("accent")
    if accent is not None and (not isinstance(accent, str) or not HEX.match(accent)):
        issues.append(Issue(p + "accent", "a hex color such as #e0573f"))
    for key in ("startDate", "deadline"):
        if key in doc and real_date(doc[key]) is None:
            issues.append(Issue(p + key, "a real date in the form YYYY-MM-DD"))
    schedule = doc.get("schedule")
    if schedule is not None:
        days = schedule.get("days") if isinstance(schedule, dict) else None
        if not isinstance(days, list) or not days or any(d not in WEEKDAYS for d in days):
            issues.append(Issue(p + "schedule.days", "a list of mon, tue, wed, thu, fri, sat, sun"))
    rem = doc.get("reminders")
    if rem is not None:
        rp = p + "reminders"
        if not isinstance(rem, dict):
            issues.append(Issue(rp, "must be an object"))
        else:
            if "preset" in rem and rem["preset"] not in PRESETS:
                issues.append(Issue(rp + ".preset", "one of gentle, firm, strict"))
            if "time" in rem and not (isinstance(rem["time"], str) and TIME.match(rem["time"])):
                issues.append(Issue(rp + ".time", "a time in the form HH:MM, for example 19:00"))
            ladder = rem.get("ladder")
            if ladder is not None:
                if not isinstance(ladder, list) or not ladder:
                    issues.append(Issue(rp + ".ladder", "a non-empty list"))
                else:
                    for i, step in enumerate(ladder):
                        sp = f"{rp}.ladder[{i}]"
                        if not isinstance(step, dict):
                            issues.append(Issue(sp, "must be an object"))
                            continue
                        if not (isinstance(step.get("at"), str) and TIME.match(step["at"])):
                            issues.append(Issue(sp + ".at", "a time in the form HH:MM"))
                        if step.get("level") not in LEVELS:
                            issues.append(Issue(sp + ".level", "one of " + ", ".join(sorted(LEVELS))))
            if not (("preset" in rem and "time" in rem) or "ladder" in rem):
                issues.append(Issue(rp, 'needs "preset" and "time", or a "ladder"'))
    if not isinstance(doc.get("data"), dict):
        issues.append(Issue(p + "data", "required, an object"))


def check_template_fields(doc, p, issues):
    for k in doc:
        if k not in TEMPLATE_FIELDS:
            issues.append(Issue(p + k, "unknown field (check the spelling)"))
    if not (isinstance(doc.get("version"), str) and SEMVER.match(doc["version"])):
        issues.append(Issue(p + "version", "required, semantic version such as 1.0.0"))
    engine = doc.get("engine")
    if engine not in ENGINES:
        issues.append(Issue(p + "engine", "one of " + ", ".join(sorted(ENGINES))))
    if "dataSchema" in doc and not isinstance(doc["dataSchema"], dict):
        issues.append(Issue(p + "dataSchema", "must be an object (a JSON Schema)"))
    surfaces = doc.get("surfaces")
    if not isinstance(surfaces, dict) or not isinstance(surfaces.get("screen"), dict):
        issues.append(Issue(p + "surfaces.screen", "required"))
    if isinstance(surfaces, dict):
        for k in surfaces:
            if k not in SURFACES:
                issues.append(Issue(f"{p}surfaces.{k}", "unknown surface; use screen, tile, tile_wide"))


def is_link_ok(v):
    return not isinstance(v, str) or v.startswith("{{") or v.startswith("https://")


def check_tree(tree, path, issues, full):
    """Size and depth always; components, actions and links when `full`."""
    count = 0

    def check_action(action, at):
        if not isinstance(action, dict):
            return
        if full and action.get("type") not in ACTIONS:
            issues.append(Issue(at + ".type", f"unknown action {json.dumps(action.get('type'))}"))
        params = action.get("params")
        if full and isinstance(params, dict) and not is_link_ok(params.get("url")):
            issues.append(Issue(at + ".params.url", "only https links are allowed"))

    def walk(node, at, depth):
        nonlocal count
        if not isinstance(node, dict):
            return
        count += 1
        if depth > MAX_DEPTH:
            issues.append(Issue(at, f"the tree is deeper than {MAX_DEPTH} levels"))
            return
        if full:
            t = node.get("type")
            if not isinstance(t, str):
                issues.append(Issue(at + ".type", "required"))
            elif t not in COMPONENTS and "fallback" not in node:
                issues.append(Issue(at + ".type", f"unknown component {json.dumps(t)}; use a known one or add a fallback"))
            for key in ("src", "url"):
                if not is_link_ok(node.get(key)):
                    issues.append(Issue(f"{at}.{key}", "only https links are allowed"))
            for key in ("action", "increment", "decrement"):
                check_action(node.get(key), f"{at}.{key}")
        children = node.get("children")
        if isinstance(children, list):
            for i, c in enumerate(children):
                walk(c, f"{at}.children[{i}]", depth + 1)
        for key in ("child", "item", "fallback"):
            walk(node.get(key), f"{at}.{key}", depth + 1)

    walk(tree, path, 1)
    if count > MAX_NODES:
        issues.append(Issue(path, f"the tree has more than {MAX_NODES} nodes"))


# ------------------------------------------------------------ shared checks

def check_semantics(doc, p, template, issues):
    data = doc.get("data")
    if not isinstance(data, dict):
        return
    start, end = real_date(doc.get("startDate")), real_date(doc.get("deadline"))
    if start and end and end < start:
        issues.append(Issue(p + "deadline", "is before startDate"))
    for key in ("items", "steps"):
        seen = {}
        for i, it in enumerate(data.get(key) or []):
            if isinstance(it, dict) and isinstance(it.get("id"), str):
                if it["id"] in seen:
                    issues.append(Issue(f"{p}data.{key}[{i}].id",
                                        f"duplicate id {json.dumps(it['id'])} (also at {key}[{seen[it['id']]}])"))
                seen.setdefault(it["id"], i)
    pages = data.get("pages")
    if isinstance(pages, dict) and isinstance(pages.get("start"), int) and isinstance(pages.get("end"), int):
        if pages["end"] < pages["start"]:
            issues.append(Issue(p + "data.pages.end", "is before pages.start"))
    if template and template.get("engine") == "by_mode" and data.get("mode") == "check" and "target" in data:
        issues.append(Issue(p + "data.target", "is ignored in check mode", warning=True))


def validate_text(text, use_jsonschema):
    issues = []
    if len(text.encode("utf-8")) > MAX_BYTES:
        return [Issue("", "the document is larger than 1 MB")]
    try:
        root = json.loads(text)
    except json.JSONDecodeError as e:
        m = FENCE.search(text)
        if not m:
            return [Issue("", f"not valid JSON: {e}")]
        try:
            root = json.loads(m.group(1))
        except json.JSONDecodeError as e2:
            return [Issue("", f"not valid JSON inside the code block: {e2}")]
        issues.append(Issue("", "JSON was inside a code fence; the app accepts that, but save the file as plain JSON",
                            warning=True))
    if not isinstance(root, dict):
        return [Issue("", "expected a JSON object")]

    kind = root.get("kind")
    if kind not in ("goal", "template", "bundle"):
        return issues + [Issue("kind", 'required: "goal", "template" or "bundle"')]

    docs = []
    if kind == "bundle":
        if use_jsonschema:
            issues += schema_issues(root, "bundle")
        else:
            check_envelope(root, "", issues)
            for k in root:
                if k not in ("kind", "schemaVersion", "documents"):
                    issues.append(Issue(k, "unknown field (check the spelling)"))
        lst = root.get("documents")
        if not isinstance(lst, list) or not lst:
            if not use_jsonschema:
                issues.append(Issue("documents", "a bundle needs a non-empty documents array"))
            return issues
        for i, d in enumerate(lst):
            p = f"documents[{i}]."
            if not isinstance(d, dict):
                if not use_jsonschema:
                    issues.append(Issue(p[:-1], "expected an object"))
                continue
            if not use_jsonschema:
                check_envelope(d, p, issues, root.get("schemaVersion"))
                if d.get("kind") not in ("goal", "template"):
                    issues.append(Issue(p + "kind", 'must be "goal" or "template"'))
            docs.append((p, d))
    else:
        if use_jsonschema:
            issues += schema_issues(root, kind)
        else:
            check_envelope(root, "", issues)
        docs.append(("", root))

    builtin = builtin_templates()
    local = {}
    for p, d in docs:
        if d.get("kind") != "template":
            continue
        if not use_jsonschema:
            check_template_fields(d, p, issues)
        surfaces = d.get("surfaces")
        if isinstance(surfaces, dict):
            for name, tree in surfaces.items():
                if isinstance(tree, dict):
                    check_tree(tree, f"{p}surfaces.{name}", issues, full=not use_jsonschema)
        schema = d.get("dataSchema")
        if use_jsonschema and isinstance(schema, dict):
            import jsonschema

            try:
                jsonschema.Draft202012Validator.check_schema(schema)
            except jsonschema.SchemaError as e:
                issues.append(Issue(p + "dataSchema", f"not a valid JSON Schema: {e.message}"))
        if isinstance(d.get("id"), str) and isinstance(d.get("version"), str) and SEMVER.match(d["version"]):
            ref = f"{d['id']}@{d['version'].split('.')[0]}"
            if ref in builtin:
                issues.append(Issue(p + "id", f"{ref} is a built-in template; pick another id", warning=True))
            local[ref] = d

    for p, d in docs:
        if d.get("kind") != "goal":
            continue
        if not use_jsonschema:
            check_goal_fields(d, p, issues)
        ref = d.get("template")
        template = local.get(ref) or builtin.get(ref)
        if isinstance(ref, str) and TEMPLATE_REF.match(ref) and template is None:
            issues.append(Issue(p + "template", f'"{ref}" is not built in and not in this file. The app rejects '
                                "the goal unless the user already installed that template.", warning=True))
        data = d.get("data")
        if template is not None and isinstance(data, dict) and isinstance(template.get("dataSchema"), dict):
            # jsonschema mode already checked built-in data through goal.schema.json.
            if ref in local or not use_jsonschema:
                issues += data_issues(template["dataSchema"], data, p + "data", use_jsonschema)
        check_semantics(d, p, template, issues)
    return issues


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    force_fallback = "--no-jsonschema" in args
    files = [a for a in args if a != "--no-jsonschema"]
    if not files or any(a in ("-h", "--help") for a in files):
        print(__doc__.strip())
        return 0 if files else 2

    use_jsonschema = False
    if not force_fallback:
        try:
            import jsonschema  # noqa: F401
            use_jsonschema = True
        except ImportError:
            print("note: the jsonschema package is not installed, so the built-in checks run instead.\n"
                  "      For the full schema check, run: pip install jsonschema", file=sys.stderr)
    mode = "jsonschema" if use_jsonschema else "built-in checks"

    failed = 0
    for f in files:
        try:
            text = Path(f).read_text(encoding="utf-8")
        except OSError as e:
            print(f"INVALID {f}\n  (root): cannot read the file: {e}")
            failed += 1
            continue
        issues, seen = [], set()
        for i in validate_text(text, use_jsonschema):
            if (i.path, i.message) not in seen:
                seen.add((i.path, i.message))
                issues.append(i)
        errors = [i for i in issues if not i.warning]
        warnings = [i for i in issues if i.warning]
        print(f"{'INVALID' if errors else 'OK'} {f} ({mode})")
        for i in errors:
            print(f"  error: {i}")
        for i in warnings:
            print(f"  warning: {i}")
        failed += bool(errors)
    if len(files) > 1:
        print(f"{len(files) - failed} valid, {failed} invalid")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
