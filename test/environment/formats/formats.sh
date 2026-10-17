#!/bin/bash
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
#
#
# Text format conversion checks, from the plugin root:
#   MIRROR_CKEDITOR_PATH=/path/to/redmine_ckeditor bash test/environment/formats/formats.sh [5.1.13]
# The destination base image redmine-mirror-test:<version> comes from versions.sh. The
# stack and its volumes are deleted at the end unless MIRROR_KEEP_STACK=1.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
export MIRROR_DESTINATION_VERSION=${1:-5.1.13}
compose=(docker compose -p "redmine-mirror-formats-${MIRROR_DESTINATION_VERSION//./-}"
  -f test/environment/compose.yml -f test/environment/compose.formats.yml)
if [ "${MIRROR_KEEP_STACK:-}" = 1 ]; then
  trap 'echo "Kept: ${compose[*]} down -v"' EXIT
else
  trap '"${compose[@]}" down -v --remove-orphans > /dev/null 2>&1 || true' EXIT
fi
"${compose[@]}" up -d --build --wait
"${compose[@]}" exec -T source timeout 300 bundle exec rails runner /mirror-environment/formats/formats_seed.rb
"${compose[@]}" exec -T destination bundle exec rails runner /mirror-environment/formats/formats_smoke.rb 2>&1 |
  grep -vE '^\s+from |ostruct|Gemfile or gemspec| INFO -- '
