#!/usr/bin/env bash
# File: redmine_mirror/scripts/package.sh
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.

set -euo pipefail
plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$plugin_root"
revision=${1:-HEAD}
[ "$#" -le 1 ] || { echo "Usage: bash scripts/package.sh [HEAD|tag]" >&2; exit 2; }
# Resolve one immutable commit before reading its metadata and tree.
commit=$(git rev-parse --verify --end-of-options "${revision}^{commit}")
[ "$(git rev-parse --show-toplevel)" = "$plugin_root" ] || { echo "Run from a plugin-root Git repository" >&2; exit 1; }
version=$(git show "$commit:lib/redmine_mirror.rb" | sed -n 's/.*VERSION = "\([A-Za-z0-9.-]*\)".*/\1/p')
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || { echo "Invalid committed plugin version" >&2; exit 1; }
if [[ "$revision" == v* ]] && [ "$revision" != "v$version" ]; then
  echo "Tag and committed version disagree" >&2
  exit 1
fi
mkdir -p dist
archive="redmine_mirror-$version.tar.gz"
# Disallow overwrite of an existing candidate; avoid mistaking two commits for one artifact.
[ ! -e "dist/$archive" ] || { echo "Candidate already exists: dist/$archive" >&2; exit 1; }
temporary=$(mktemp "dist/.mirror-package.XXXXXX")
trap 'rm -f "$temporary"' EXIT
git archive --format=tar --prefix=redmine_mirror/ "$commit" | gzip -n > "$temporary"
tar tzf "$temporary" > /dev/null
mv "$temporary" "dist/$archive"
(cd dist && sha256sum "$archive" > "$archive.sha256")
printf 'Candidate commit: %s\nArchive: %s/dist/%s\n' "$commit" "$plugin_root" "$archive"
