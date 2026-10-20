#!/bin/bash
# File: redmine_mirror/test/environment/boot.sh
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
case "${MIRROR_ROLE:-}" in source|destination) ;; *) exit 1 ;; esac
cd /usr/src/redmine
rm -rf plugins/redmine_sla plugins/redmine_reporting plugins/redmine_mirror
# A 6.1 source runs Mirror too, for the Documents module; older sources do not.
if [ "$MIRROR_ROLE" = destination ] || [ "${MIRROR_SOURCE_PLUGIN:-}" = 1 ]; then cp -a /mirror-plugin plugins/redmine_mirror; fi
# Optional, with compose.reporting.yml: the Reporting adapters need Reporting on both sides.
if [ -d /reporting-plugin ]; then cp -a /reporting-plugin plugins/redmine_reporting; fi
cat > config/database.yml <<'YAML'
production:
  adapter: sqlite3
  database: /mirror-data/manual.sqlite3
  pool: 5
  timeout: 5000
test:
  adapter: sqlite3
  database: /mirror-data/automated.sqlite3
  pool: 5
  timeout: 5000
YAML
mkdir -p config/initializers
cat > config/initializers/mirror_test_schema.rb <<'RUBY'
Rails.application.config.active_record.schema_format = :ruby
Rails.application.config.action_mailer.delivery_method = :test
# Background mail jobs read SQLite while seeds write it; run them in the same thread.
Rails.application.config.active_job.queue_adapter = :inline
RUBY
cat > config/additional_environment.rb <<'RUBY'
config.session_store :cookie_store,
  key: "_redmine_mirror_#{ENV.fetch('MIRROR_ROLE')}_session",
  path: '/', same_site: :lax
RUBY
cat > config/configuration.yml <<YAML
default:
  autologin_cookie_name: redmine_mirror_${MIRROR_ROLE}_autologin
  attachments_storage_path: /mirror-data/files
  database_cipher_key: mirror-disposable-database-cipher-key-test-only
YAML
bundle check
bundle exec rake db:migrate redmine:plugins:migrate
# No notification emails: their background jobs read SQLite while the seeds write it,
# which made the Redmine 4.2 source fail with "database is locked".
bundle exec rails runner 'Setting.notified_events = []'
if [ ! -f /mirror-data/seeded ]; then
  REDMINE_LANG=en bundle exec rake redmine:load_default_data
  bundle exec rails runner /mirror-environment/seed.rb
  touch /mirror-data/seeded
fi
bundle exec rails runner /mirror-environment/api_token.rb
if [ -d plugins/redmine_reporting ] && [ "$MIRROR_ROLE" = source ] && [ "${MIRROR_WORKER:-}" != 1 ]; then
  bundle exec rails runner /mirror-environment/reporting_seed.rb
fi
if [ "${MIRROR_WORKER:-}" = 1 ]; then
  exec bash /mirror-environment/worker.sh
fi
exec bundle exec rails server -b 0.0.0.0 -p 3000
