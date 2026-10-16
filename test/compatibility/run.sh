#!/usr/bin/env bash
# File: redmine_mirror/test/compatibility/run.sh
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
plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
results=$(mktemp -d "${TMPDIR:-/tmp}/redmine-mirror-compat.XXXXXX")
image=redmine-mirror-ci:6.1.4
# Snapshot only public plugin source; never mount an editable checkout or local secret files.
mkdir "$results/plugin"
tar -C "$plugin_root" --exclude=.git --exclude=dist --exclude=tmp --exclude=log \
  --exclude=mirror.json --exclude='.env*' -cf - . | tar -C "$results/plugin" -xf -
container="mirror-ci-$(basename "$results")"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
printf 'Diagnostics: %s\n' "$results"
docker build -t "$image" -f "$results/plugin/test/compatibility/Dockerfile" "$results/plugin/test/compatibility" 2>&1 | tee "$results/build.log"
docker run --name "$container" --entrypoint bash \
  -e MIRROR_TEST_ENVIRONMENT=disposable \
  -v "$results/plugin:/mirror-plugin:ro" -v "$results:/mirror-results" \
  "$image" /mirror-plugin/test/compatibility/container.sh 2>&1 | tee "$results/test.log"
