# File: redmine_mirror/test/environment/Dockerfile
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

# The destination Redmine version is selectable for cross-version checks (versions.sh).
ARG BASE_IMAGE=reporting-compat-ready:6.1.4
FROM ${BASE_IMAGE}
USER root
RUN rm -rf plugins/redmine_sla plugins/redmine_reporting \
 && printf 'production:\n  adapter: sqlite3\n  database: /mirror-data/manual.sqlite3\ntest:\n  adapter: sqlite3\n  database: /mirror-data/automated.sqlite3\n' > config/database.yml \
 && rm -f Gemfile.lock \
 && bundle install
