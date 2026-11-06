# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# prints the Python version a repository pins, read from the repository, never chosen by CI.
# Order: `.python-version` (first line), then `Pipfile` [requires] python_full_version / python_version,
# then `pyproject.toml` [project] requires-python (its first x.y[.z]). Fails, naming the files it read,
# when none states an explicit version, or when what it states is only a major ("3", "3.x").
# Usage: bash .github/scripts/kskill-python-version.sh [<repo-root>]   (prints e.g. "3.14.7" or "3.14")
set -euo pipefail

cd "${1:-.}"

from_python_version() {
  [ -f .python-version ] || return 0
  sed -n '1{s/[[:space:]]//g;p;}' .python-version
}

from_pipfile() { # python_full_version wins over python_version, both under [requires]
  [ -f Pipfile ] || return 0
  awk '
    /^\[/ { section = $0 }
    section == "[requires]" && $1 == "python_full_version" { gsub(/["[:space:]]/, "", $0); sub(/^python_full_version=/, "", $0); full = $0 }
    section == "[requires]" && $1 == "python_version" { gsub(/["[:space:]]/, "", $0); sub(/^python_version=/, "", $0); short = $0 }
    END { if (full != "") print full; else if (short != "") print short }
  ' Pipfile
}

from_pyproject() { # first x.y[.z] in requires-python, e.g. ">=3.14,<3.15" gives 3.14
  [ -f pyproject.toml ] || return 0
  sed -n 's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' pyproject.toml |
    grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true
}

version=""
for source in from_python_version from_pipfile from_pyproject; do
  version=$($source)
  [ -n "$version" ] && break
done

if [ -z "$version" ]; then
  echo "::error::No Python version found: add .python-version (preferred), or python_version under [requires] in Pipfile, or requires-python in pyproject.toml." >&2
  exit 1
fi
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
  echo "::error::Python version \"$version\" is not an explicit x.y or x.y.z: pin it, never a floating channel." >&2
  exit 1
fi
echo "$version"
