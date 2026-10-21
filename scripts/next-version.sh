#!/usr/bin/env bash
# The number the next release will carry, worked out rather than typed.
#
# The repo holds no version. The newest release does, and this walks one step
# past it at the level asked for: the step is always one, and everything to the
# right of it goes to zero. A number nobody types cannot be mistyped, and one
# derived from the newest release cannot collide with a release that exists.
#
#   ./scripts/next-version.sh patch   # 1.4.1 -> 1.4.2
#   ./scripts/next-version.sh minor   # 1.4.1 -> 1.5.0
#   ./scripts/next-version.sh major   # 1.4.1 -> 2.0.0

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-kamrul1157024/get-on-it}"

bump="${1:-patch}"
case "$bump" in
    patch | minor | major) ;;
    *)
        printf 'Usage: %s [patch|minor|major]\n' "$0" >&2
        exit 1
        ;;
esac

# The newest release, not the newest tag: a tag can be a prerelease or a
# mistake. An unreachable GitHub is fatal — a guessed base is a wrong number.
# `gh release view` fails both when GitHub is unreachable and when there is no
# release yet, so the two are told apart with `gh release list`.
if ! list=$(gh release list --repo "$REPO" --limit 1 --json tagName -q '.[0].tagName // ""' 2> /dev/null); then
    printf 'Error: could not reach GitHub for the releases of %s.\n' "$REPO" >&2
    exit 1
fi
released=${list#v}

# No release yet: the first one is whichever component was asked for, off zero.
[ -n "$released" ] || released=0.0.0

if ! printf '%s' "$released" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'Error: newest release is "%s", which is not a x.y.z number.\n' "$released" >&2
    exit 1
fi

IFS=. read -r major minor patch <<< "$released"

case "$bump" in
    major) printf '%d.0.0\n' "$((major + 1))" ;;
    minor) printf '%d.%d.0\n' "$major" "$((minor + 1))" ;;
    patch) printf '%d.%d.%d\n' "$major" "$minor" "$((patch + 1))" ;;
esac
