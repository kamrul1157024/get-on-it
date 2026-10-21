#!/usr/bin/env python3
"""Turn a YouTube playlist into course@1 items for Get On It.

Usage:
  playlist_to_items.py <playlist-url> [--per-week N] [--check-embed] [--limit N]

Prints a JSON array of items to stdout. Notes and warnings go to stderr.
Needs yt-dlp: the Python module if it can be imported, else the `yt-dlp` CLI.
Only the standard library is used besides yt-dlp.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys

INSTALL_HINT = (
    "yt-dlp is not installed. Install it with one of:\n"
    "  pip install yt-dlp\n"
    "  pipx install yt-dlp\n"
    "  brew install yt-dlp        (macOS)\n"
    "Then run this script again."
)

SEASON = re.compile(r"[-(\[]?\s*\b(?:autumn|fall|spring|summer|winter)\s*'?\d{2,4}\b\s*[)\]]?", re.I)
LECTURE = re.compile(r"\b(?:lecture|lec\.?)\s*#?\s*(\d{1,3})\b", re.I)
SEPARATORS = re.compile(r"\s*(?:\||\s[-–—]\s|\s[-–—](?=\S)|:\s)\s*")
WORD = re.compile(r"[a-z0-9]+")
UNAVAILABLE = {"[private video]", "[deleted video]", "[unavailable video]"}


def die(message, code=2):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- yt-dlp access

def _module():
    try:
        import yt_dlp  # noqa: F401
        return yt_dlp
    except ImportError:
        return None


def fetch_json(url, flat):
    """Return yt-dlp's JSON info for a URL (flat playlist or one full video)."""
    mod = _module()
    if mod is not None:
        opts = {"quiet": True, "no_warnings": True, "skip_download": True, "ignore_no_formats_error": True}
        if flat:
            opts["extract_flat"] = "in_playlist"
        try:
            with mod.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url, download=False)
                return ydl.sanitize_info(info)
        except Exception as e:  # yt-dlp raises its own DownloadError subclasses
            raise RuntimeError(str(e)) from e
    exe = shutil.which("yt-dlp")
    if exe is None:
        die(INSTALL_HINT)
    cmd = [exe, "-J", "--no-warnings", "--skip-download"]
    if flat:
        cmd.append("--flat-playlist")
    cmd.append(url)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"yt-dlp exited with code {proc.returncode}")
    return json.loads(proc.stdout)


# ---------------------------------------------------------------- titles and ids

def _words(text):
    return set(WORD.findall(text.lower()))


def frequent_words(titles, playlist_title=""):
    """Words that repeat across titles, such as the course or teacher name.

    A word is noise when it is in at least a quarter of the titles (and in 3
    or more), or when it is in the playlist title and in 2 or more titles.
    """
    counts = {}
    for t in titles:
        for w in _words(SEASON.sub(" ", t)):
            counts[w] = counts.get(w, 0) + 1
    in_playlist = _words(SEASON.sub(" ", playlist_title or ""))
    limit = max(3, len(titles) / 4)
    return {w for w, n in counts.items() if n >= limit or (w in in_playlist and n >= 2)}


def clean_title(raw, noise):
    """Returns (lecture_number or None, topic)."""
    text = SEASON.sub(" ", raw)
    m = LECTURE.search(text)
    number = int(m.group(1)) if m else None
    kept = []
    for seg in SEPARATORS.split(text):
        seg = LECTURE.sub(" ", seg)
        seg = re.sub(r"\(\s*\)|\[\s*\]", " ", seg)
        seg = re.sub(r"\s+", " ", seg).strip(" -|:–—,")
        words = _words(seg)
        if not words or words <= noise:
            continue
        kept.append(seg)
    topic = ": ".join(kept) if kept else ""
    return number, topic


def slug(text, limit=40):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:limit].rstrip("-")


def build_items(entries, per_week, noise):
    width = 3 if len(entries) > 99 else 2
    items, seen = [], set()
    for order, e in enumerate(entries, start=1):
        raw = (e.get("title") or "").strip()
        number, topic = clean_title(raw, noise)
        if number is not None:
            base = f"lec-{number:0{width}d}"
            title = f"Lecture {number}: {topic}" if topic else f"Lecture {number}"
        else:
            title = topic or raw or f"Video {order}"
            base = slug(title) or f"video-{order:0{width}d}"
            if not re.match(r"^[a-z0-9]", base):
                base = f"video-{order:0{width}d}"
        item_id, n = base, 2
        while item_id in seen:
            item_id = f"{base}-{n}"
            n += 1
        seen.add(item_id)
        item = {"id": item_id, "kind": "video", "title": title, "videoId": e["id"]}
        if e.get("duration"):
            item["durationSec"] = int(round(e["duration"]))
        item["week"] = (order - 1) // per_week + 1
        items.append(item)
    return items


# ---------------------------------------------------------------- main

def main(argv=None):
    p = argparse.ArgumentParser(description="YouTube playlist -> Get On It course@1 items (JSON on stdout).")
    p.add_argument("url", help="playlist URL, for example https://www.youtube.com/playlist?list=...")
    p.add_argument("--per-week", type=int, default=2, metavar="N", help="videos per week (default 2)")
    p.add_argument("--check-embed", action="store_true",
                   help="fetch each video and set embeddable:false when the owner disabled embedding")
    p.add_argument("--limit", type=int, metavar="N", help="only the first N videos")
    args = p.parse_args(argv)
    if args.per_week < 1:
        die("--per-week must be 1 or more")

    try:
        info = fetch_json(args.url, flat=True)
    except RuntimeError as e:
        die(f"could not read the playlist: {e}", 1)

    entries = [e for e in (info.get("entries") or []) if e]
    if not entries and info.get("id") and info.get("_type", "video") == "video":
        entries = [info]  # a single video URL
    usable = []
    for e in entries:
        title = (e.get("title") or "").strip()
        if not e.get("id") or title.lower() in UNAVAILABLE:
            print(f"warning: skipped unavailable video {e.get('id')} ({title or 'no title'})", file=sys.stderr)
            continue
        usable.append(e)
    if not usable:
        die("the playlist has no available videos", 1)
    # Learn the repeated words from the whole playlist, even with --limit.
    noise = frequent_words([e.get("title") or "" for e in usable], info.get("title") or "")
    if args.limit:
        usable = usable[: args.limit]

    items = build_items(usable, args.per_week, noise)

    disabled = 0
    for item in items:
        need_full = args.check_embed or "durationSec" not in item
        if not need_full:
            continue
        try:
            full = fetch_json(f"https://www.youtube.com/watch?v={item['videoId']}", flat=False)
        except RuntimeError as e:
            print(f"warning: {item['id']} ({item['videoId']}): could not fetch video info: {e}", file=sys.stderr)
            continue
        if "durationSec" not in item and full.get("duration"):
            item["durationSec"] = int(round(full["duration"]))
            item = _reorder(item)
        if args.check_embed:
            embed = full.get("playable_in_embed")
            if embed is False:
                item["embeddable"] = False
                disabled += 1
            print(f"embed: {item['id']} {item['videoId']} playable_in_embed={embed}", file=sys.stderr)

    for item in items:
        if "durationSec" not in item:
            print(f"warning: {item['id']} has no duration. Add durationSec by hand.", file=sys.stderr)

    print(f"{len(items)} videos, {sum(i.get('durationSec', 0) for i in items) / 3600:.1f} h, "
          f"{items[-1]['week']} weeks at {args.per_week} per week"
          + (f", embedding disabled on {disabled}" if args.check_embed else ""), file=sys.stderr)
    json.dump(items, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def _reorder(item):
    # Keep the key order stable (durationSec before week) after a late fill.
    order = ["id", "kind", "title", "videoId", "durationSec", "week", "embeddable"]
    snapshot = dict(item)
    item.clear()
    item.update({k: snapshot[k] for k in order if k in snapshot})
    return item


if __name__ == "__main__":
    sys.exit(main())
