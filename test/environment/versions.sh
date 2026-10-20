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
# Run the write smokes from an older source Redmine into a Mirror destination, from the
# plugin root:   bash test/environment/versions.sh redmine:4.2 6.1.4
# Each pair gets its own disposable stack and volumes, deleted at the end; the main
# environment's stack and data are untouched (stop it first: both publish the same ports).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export MIRROR_SOURCE_IMAGE=${1:?Usage: versions.sh SOURCE_IMAGE DESTINATION_VERSION}
export MIRROR_DESTINATION_VERSION=${2:?Usage: versions.sh SOURCE_IMAGE DESTINATION_VERSION}
stack="redmine-mirror-versions-$(printf '%s-%s' "$1" "$2" | tr -c 'a-z0-9' '-')"
compose=(docker compose -p "$stack" -f test/environment/compose.yml -f test/environment/compose.versions.yml)
# MIRROR_KEEP_STACK=1 keeps the stack for investigation; remove it with the printed command.
if [ "${MIRROR_KEEP_STACK:-}" = 1 ]; then
  trap 'echo "Kept: ${compose[*]} down -v"' EXIT
else
  trap '"${compose[@]}" down -v --remove-orphans > /dev/null 2>&1 || true' EXIT
fi
"${compose[@]}" up -d --build --wait
"${compose[@]}" exec -T source bundle exec rails runner 'puts "Source Redmine #{Redmine::VERSION} / Ruby #{RUBY_VERSION}"'
"${compose[@]}" exec -T destination bundle exec rails runner 'puts "Destination Redmine #{Redmine::VERSION} / Ruby #{RUBY_VERSION} / Mirror #{RedmineMirror::VERSION}"'
run() {
  "${compose[@]}" exec -T "$@" destination bundle exec rails runner "/mirror-environment/$script.rb" 2>&1 |
    grep -vE '^\s+from |ostruct|Gemfile or gemspec| INFO -- ' | tail -3
}
# Fixtures the boot seed does not load, used by the smokes of the same name.
for seed in issue_state_seed custom_fields_seed locked_seed wiki_seed members_seed files_seed; do
  # A seed normally takes seconds, but the Redmine 4.2 source occasionally stalls: bound
  # each attempt and retry once (the seeds are idempotent).
  "${compose[@]}" exec -T source timeout 300 bundle exec rails runner "/mirror-environment/$seed.rb" > /dev/null ||
    "${compose[@]}" exec -T source timeout 300 bundle exec rails runner "/mirror-environment/$seed.rb" > /dev/null
done
# MIRROR_SOURCE_ACCOUNT=reader configures the connection with a non-administrator key.
key_args=()
if [ "${MIRROR_SOURCE_ACCOUNT:-admin}" = reader ]; then
  "${compose[@]}" exec -T source bundle exec rails runner /mirror-environment/reader_account.rb
  key_args=(-e "MIRROR_SOURCE_API_KEY=$(printf '3%.0s' $(seq 40))")
fi
script=ui_smoke run "${key_args[@]}"
script=ui_smoke run "${key_args[@]}" -e MIRROR_ENABLE_HISTORY=1 -e MIRROR_REFRESH_TEST=1 -e MIRROR_COMPLETE_STATUS_MAPPINGS=1
failed=0
for script in smoke synchronization_smoke history_smoke relations_smoke issue_state_smoke custom_fields_smoke conflicts_smoke locked_smoke wiki_smoke members_smoke mirror_mode_smoke files_smoke; do
  # smoke.rb otherwise assumes identical IDs on both sides; use the UI mappings instead.
  output=$(run -e MIRROR_PROJECT_CONFIG_SMOKE=1) || true
  if grep -q "passed" <<< "$output"; then echo "PASS $script"; else echo "FAIL $script: $output"; failed=1; fi
done
exit "$failed"
