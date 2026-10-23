#!/usr/bin/env python3
"""Build docs/privacy.html (the page GitHub Pages serves) from docs/privacy.md.

Usage: scripts/privacy_html.py [--check]

docs/ has a .nojekyll file, because Jekyll fails on the {{bindings}} in other
docs. So Pages serves files as they are, and this script turns the small
Markdown subset of the policy (# headings, paragraphs, - lists, links) into
HTML. With --check it only reports whether the HTML is out of date.
Standard library only.
"""

import html
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parents[1] / "docs"
STYLE = (
    "body{font-family:system-ui,sans-serif;max-width:42rem;margin:2rem auto;padding:0 1rem;"
    "line-height:1.55;color:#1c1b1f}h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:1.6rem}"
    "a{color:#5b45c9}"
)


def inline(text):
    text = html.escape(text, quote=False)
    return re.sub(r"(https://[^\s,)]+[^\s,).])", r'<a href="\1">\1</a>', text)


def render(markdown):
    out, in_list = [], False
    for line in markdown.splitlines():
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>" + inline(line[2:]) + "</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.startswith("## "):
            out.append("<h2>" + inline(line[3:]) + "</h2>")
        elif line.startswith("# "):
            out.append("<h1>" + inline(line[2:]) + "</h1>")
        elif line.strip():
            out.append("<p>" + inline(line) + "</p>")
    if in_list:
        out.append("</ul>")
    return (
        '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        "<title>Get On It: privacy policy</title>\n"
        f"<style>{STYLE}</style>\n</head>\n<body>\n"
        "<!-- Generated from docs/privacy.md by scripts/privacy_html.py. Edit the Markdown, then run the script. -->\n"
        + "\n".join(out)
        + "\n</body>\n</html>\n"
    )


def main(argv):
    want = render((DOCS / "privacy.md").read_text(encoding="utf-8"))
    target = DOCS / "privacy.html"
    if "--check" in argv:
        if not target.exists() or target.read_text(encoding="utf-8") != want:
            print("out of date: docs/privacy.html (run scripts/privacy_html.py)")
            return 1
        print("docs/privacy.html is up to date")
        return 0
    target.write_text(want, encoding="utf-8")
    print("wrote docs/privacy.html")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
