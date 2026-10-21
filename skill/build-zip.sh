#!/usr/bin/env bash
# Builds dist/getonit-planner.zip (next to this script) for upload to claude.ai.
# The zip root is the folder getonit-planner/ with SKILL.md inside.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/skills/getonit-planner"
out="$here/dist/getonit-planner.zip"

mkdir -p "$here/dist"
rm -f "$out"

python3 - "$src" "$out" <<'PY'
import sys, zipfile
from pathlib import Path

src, out = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(src.rglob("*")):
        if f.is_dir() or "__pycache__" in f.parts or f.suffix == ".pyc" or f.name == ".DS_Store":
            continue
        z.write(f, Path("getonit-planner") / f.relative_to(src))
PY

echo "built $out"
