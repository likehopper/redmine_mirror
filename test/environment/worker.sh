#!/bin/bash
# File: redmine_mirror/test/environment/worker.sh
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
# Configure or run the isolated local Redmine integration-test environment.

set -euo pipefail
[ "${MIRROR_TEST_ENVIRONMENT:-}" = disposable ] || exit 1
while true; do
  bundle exec rake redmine_mirror:tick || true
  sleep 15
done
