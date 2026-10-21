#!/usr/bin/env bash
# File: redmine_mirror/test/documentation/run.sh
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
# Regenerate the screenshots of doc/CONFIGURATION.md and doc/MIRROR_COPY.md in one
# disposable container: a plain source Redmine serves its API on port 3001, the browser
# tests are the destination. The mirror copy guide runs after the configuration guide.

set -euo pipefail
plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
results=$(mktemp -d "${TMPDIR:-/tmp}/redmine-mirror-doc.XXXXXX")
image=redmine-mirror-ci:6.1.4
mkdir "$results/plugin" "$results/screenshots"
tar -C "$plugin_root" --exclude=.git --exclude=dist --exclude=tmp --exclude=log \
  --exclude=mirror.json --exclude='.env*' -cf - . | tar -C "$results/plugin" -xf -
printf 'Logs: %s\n' "$results"
docker build -t "$image" -f "$results/plugin/test/compatibility/Dockerfile" \
  "$results/plugin/test/compatibility" > "$results/build.log" 2>&1
docker run --rm --cpus=2 --memory=3g --entrypoint bash -e MIRROR_TEST_ENVIRONMENT=disposable \
  -v "$results/plugin:/plugin:ro" -v "$results/screenshots:/screenshots" "$image" -c '
set -euo pipefail
cd /usr/src/redmine
# The Gemfile reads the database adapter from config/database.yml.
printf "test:\n  adapter: sqlite3\n  database: db/mirror_doc.sqlite3\n" > config/database.yml
rm -f Gemfile.lock
bundle install
# The source is a plain Redmine: Mirror only needs its REST API.
cp -a /usr/src/redmine /usr/src/source
echo "127.0.0.1 redmine-source" >> /etc/hosts
# The seed scripts of the two-instance environment expect these paths.
ln -s /plugin/test/environment /mirror-environment
mkdir -p /mirror-data/files
(
  cd /usr/src/source
  printf "production:\n  adapter: sqlite3\n  database: /mirror-data/source.sqlite3\n" > config/database.yml
  printf "default:\n  attachments_storage_path: /mirror-data/files\n" > config/configuration.yml
  export RAILS_ENV=production MIRROR_ROLE=source
  export SECRET_KEY_BASE=mirror-disposable-doc-secret-only-abcdefghijklmnopqrstuvwxyz0123456789
  bundle exec rake db:migrate
  REDMINE_LANG=en bundle exec rake redmine:load_default_data
  bundle exec rails runner /mirror-environment/seed.rb
  bundle exec rails runner /mirror-environment/api_token.rb
  bundle exec rails server -b 127.0.0.1 -p 3001 -d
)
ruby -rnet/http -e "60.times { break if (Net::HTTP.get_response(URI(%q(http://redmine-source:3001/login))) rescue nil); sleep 1 }"
cp -a /plugin plugins/redmine_mirror
printf "default:\n  database_cipher_key: mirror-disposable-doc-cipher-key-only\n" > config/configuration.yml
cat > config/initializers/mirror_doc.rb <<RUBY
Rails.application.config.active_record.schema_format = :ruby
Rails.application.config.action_mailer.delivery_method = :test
RUBY
export RAILS_ENV=test CHROMEDRIVER_PATH=/usr/bin/chromedriver
export GOOGLE_CHROME_OPTS_ARGS=headless,disable-gpu,no-sandbox,disable-dev-shm-usage
# The test server is the destination: the worker writes to it through the REST API.
export CAPYBARA_SERVER_HOST=127.0.0.1 CAPYBARA_SERVER_PORT=3002
export MIRROR_DESTINATION_URL=http://127.0.0.1:3002 MIRROR_DESTINATION_API_KEY=2222222222222222222222222222222222222222
export MIRROR_SOURCE_URL=http://redmine-source:3001 MIRROR_SOURCE_API_KEY=1111111111111111111111111111111111111111
export MIRROR_DOC_SCREENSHOTS=/screenshots
bundle exec rake db:migrate redmine:plugins:migrate
bundle exec ruby -Itest plugins/redmine_mirror/test/documentation/configuration_test.rb -v
bundle exec ruby -Itest plugins/redmine_mirror/test/documentation/mirror_copy_test.rb -v
' > "$results/run.log" 2>&1 || { echo "Documentation run failed: see $results/run.log" >&2; exit 1; }
mkdir -p "$plugin_root/doc/images" "$plugin_root/doc/screenshots/configuration"
mv "$results/screenshots/home.png" "$plugin_root/doc/images/redmine_mirror_home.png"
cp "$results/screenshots/"*.png "$plugin_root/doc/screenshots/configuration/"
mkdir -p "$plugin_root/doc/screenshots/mirror-copy"
cp "$results/screenshots/mirror-copy/"*.png "$plugin_root/doc/screenshots/mirror-copy/"
printf 'Screenshots copied to %s and %s\n' "$plugin_root/doc/screenshots/configuration" "$plugin_root/doc/screenshots/mirror-copy"
