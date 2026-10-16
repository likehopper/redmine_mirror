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
# Run the Reporting adapter checks across both instances, from the plugin root:
#   MIRROR_REPORTING_PATH=/path/to/redmine_reporting bash test/environment/reporting_smoke.sh
# The stack must be up with compose.reporting.yml. The source data is reset afterwards.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
compose=(docker compose -f test/environment/compose.yml -f test/environment/compose.reporting.yml)
seed_source() {
  "${compose[@]}" exec -T "$@" source bundle exec rails runner /mirror-environment/reporting_seed.rb
}
destination_step() {
  "${compose[@]}" exec -T -e "REPORTING_SMOKE_STEP=$1" destination bundle exec rails runner /mirror-environment/reporting_smoke.rb
}
trap 'destination_step cleanup || true; seed_source || true' EXIT
seed_source
destination_step import
seed_source -e MIRROR_REPORTING_VARIANT=updated
destination_step update
