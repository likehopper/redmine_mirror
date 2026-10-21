#!/usr/bin/env bash
# File: redmine_mirror/test/documentation/migration_run.sh
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
# Regenerate doc/MIGRATION_4_TO_5.md's screenshots: an official Redmine 4.2 source (its own
# container, Ruby 2.7) and a Redmine 5.1 destination whose browser test drives both.
#   bash test/documentation/migration_run.sh [SOURCE_IMAGE] [DESTINATION_IMAGE]
# Defaults: redmine:4.2 and reporting-compat-ready:5.1.13 (Redmine 5.1 with Chromium).

set -euo pipefail
plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source_image=${1:-redmine:4.2}
destination_image=${2:-reporting-compat-ready:5.1.13}
results=$(mktemp -d "${TMPDIR:-/tmp}/redmine-mirror-migration.XXXXXX")
name="mirror-migration-$(basename "$results" | tr -c 'a-zA-Z0-9\n' '-' | tr 'A-Z' 'a-z')"
mkdir "$results/plugin" "$results/screenshots" "$results/source-data"
tar -C "$plugin_root" --exclude=.git --exclude=dist --exclude=tmp --exclude=log \
  --exclude=mirror.json --exclude='.env*' -cf - . | tar -C "$results/plugin" -xf -
printf 'Logs: %s\n' "$results"
cleanup() {
  docker rm -f "$name-source" > /dev/null 2>&1 || true
  docker network rm "$name" > /dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$name" > /dev/null
# The source: the official image, seeded demo data, as test/environment does it.
docker run -d --name "$name-source" --network "$name" --network-alias redmine-source \
  -e RAILS_ENV=production -e SECRET_KEY_BASE=mirror-disposable-test-only-secret-abcdefghijklmnopqrstuvwxyz0123456789 \
  -e MIRROR_TEST_ENVIRONMENT=disposable -e MIRROR_ROLE=source -e MIRROR_SOURCE_PLUGIN=0 \
  -v "$results/plugin/test/environment:/mirror-environment:ro" -v "$results/plugin:/mirror-plugin:ro" \
  -v "$results/source-data:/mirror-data" --entrypoint bash "$source_image" /mirror-environment/boot.sh > /dev/null
for _ in $(seq 120); do
  if docker exec "$name-source" ruby -rnet/http -e "exit Net::HTTP.get_response(URI('http://127.0.0.1:3000/login')).code == '200'" 2> /dev/null; then break; fi
  sleep 5
done
docker exec "$name-source" ruby -rnet/http -e "exit Net::HTTP.get_response(URI('http://127.0.0.1:3000/login')).code == '200'" \
  || { docker logs "$name-source" > "$results/source.log" 2>&1; echo "Source did not start: see $results/source.log" >&2; exit 1; }
# The guide starts from a source whose REST API is still off.
docker exec -w /usr/src/redmine "$name-source" \
  bundle exec rails runner 'Setting.rest_api_enabled = "0"' > "$results/source-prepare.log" 2>&1
docker run --rm --cpus=2 --memory=3g --network "$name" --entrypoint bash -e MIRROR_TEST_ENVIRONMENT=disposable \
  -v "$results/plugin:/plugin:ro" -v "$results/screenshots:/screenshots" "$destination_image" -c '
set -euo pipefail
cd /usr/src/redmine
printf "test:\n  adapter: sqlite3\n  database: db/mirror_migration.sqlite3\n" > config/database.yml
rm -f Gemfile.lock
bundle install
rm -rf plugins/redmine_mirror plugins/redmine_sla plugins/redmine_reporting
cp -a /plugin plugins/redmine_mirror
printf "default:\n  database_cipher_key: mirror-disposable-doc-cipher-key-only\n" > config/configuration.yml
cat > config/initializers/mirror_doc.rb <<RUBY
Rails.application.config.active_record.schema_format = :ruby
Rails.application.config.action_mailer.delivery_method = :test
RUBY
export RAILS_ENV=test CHROMEDRIVER_PATH=/usr/bin/chromedriver
export GOOGLE_CHROME_OPTS_ARGS=headless,disable-gpu,no-sandbox,disable-dev-shm-usage
export CAPYBARA_SERVER_HOST=127.0.0.1 CAPYBARA_SERVER_PORT=3002
export MIRROR_DESTINATION_URL=http://127.0.0.1:3002 MIRROR_DESTINATION_API_KEY=2222222222222222222222222222222222222222
export MIRROR_SOURCE_URL=http://redmine-source:3000 MIRROR_SOURCE_ADMIN_PASSWORD=Mirror-test-2026!
export MIRROR_DOC_SCREENSHOTS=/screenshots
bundle exec rake db:migrate redmine:plugins:migrate
bundle exec ruby -Itest plugins/redmine_mirror/test/documentation/migration_4_to_5_test.rb -v
' > "$results/run.log" 2>&1 || { docker logs "$name-source" > "$results/source.log" 2>&1; echo "Migration guide run failed: see $results/run.log" >&2; exit 1; }
mkdir -p "$plugin_root/doc/screenshots/migration"
cp "$results/screenshots/migration/"*.png "$plugin_root/doc/screenshots/migration/"
printf 'Screenshots copied to %s\n' "$plugin_root/doc/screenshots/migration"
