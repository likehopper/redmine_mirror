#!/bin/bash
# File: redmine_mirror/test/environment/tests.sh
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
cd /usr/src/redmine
exec 9>/mirror-data/automated-tests.lock
flock -n 9 || { echo "Automated tests already running"; exit 1; }
# Core fixtures reset the plugin migration registry; rebuild only the automated DB.
rm -f /mirror-data/automated.sqlite3 /mirror-data/automated.sqlite3-shm /mirror-data/automated.sqlite3-wal
# Refresh the plugin snapshot without restarting the manual server.
cp -a /mirror-plugin/. plugins/redmine_mirror/
export RAILS_ENV=test
export CHROMEDRIVER_PATH=/usr/bin/chromedriver
if ! bundle exec rake db:migrate redmine:plugins:migrate > /mirror-data/test-prepare.log 2>&1; then
  tail -80 /mirror-data/test-prepare.log
  exit 1
fi
bundle exec rake redmine:plugins:test NAME=redmine_mirror
