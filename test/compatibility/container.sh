#!/usr/bin/env bash
# File: redmine_mirror/test/compatibility/container.sh
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
[ "${MIRROR_TEST_ENVIRONMENT:-}" = disposable ] || exit 1
cd /usr/src/redmine
# Installed through a symbolic link, as in Capistrano-style deployments (shared/plugins).
mkdir -p /tmp/shared-plugins
cp -a /mirror-plugin /tmp/shared-plugins/redmine_mirror
ln -s /tmp/shared-plugins/redmine_mirror plugins/redmine_mirror
# Test plugins patching the project settings tabs like real-world plugins do (alias_method
# chains, prepend), loaded before and after Mirror: the suite checks every tab renders.
cp -a /mirror-plugin/test/compatibility/plugins/. plugins/
export MIRROR_COMPAT_PLUGINS=1
mkdir -p /mirror-results/screenshots
cat > config/database.yml <<'YAML'
test:
  adapter: sqlite3
  database: db/mirror_compat.sqlite3
  pool: 5
YAML
cat > config/configuration.yml <<'YAML'
default:
  database_cipher_key: mirror-disposable-cipher-key-only
YAML
cat > config/initializers/mirror_compat.rb <<'RUBY'
Rails.application.config.active_record.schema_format = :ruby
Rails.application.config.action_mailer.delivery_method = :test
RUBY
export RAILS_ENV=test
export SECRET_KEY_BASE=mirror-disposable-ci-secret-only-abcdefghijklmnopqrstuvwxyz0123456789
export CHROMEDRIVER_PATH=/usr/bin/chromedriver
export GOOGLE_CHROME_OPTS_ARGS=headless,disable-gpu,no-sandbox,disable-dev-shm-usage
# Resolve dependencies for the generated SQLite configuration, not the image's production defaults.
rm -f Gemfile.lock
bundle install
bundle exec rails runner 'abort "Wrong Redmine version" unless Redmine::VERSION.to_a.first(3).join(".") == "6.1.4"; puts "Redmine #{Redmine::VERSION} / Ruby #{RUBY_VERSION} / Rails #{Rails.version}"'
# Production eager-loads plugin lib/ directories: every file must match its constant.
bundle exec rails zeitwerk:check
# Loading everything, then explicitly requiring both names of the linked plugin, must
# not load Mirror a second time through either the installation or canonical path.
load_output=$(bundle exec rails runner '
  linked_lib = Rails.root.join("plugins/redmine_mirror/lib").to_s
  canonical_lib = File.realpath(linked_lib)
  Rails.application.eager_load!
  Dir.glob(File.join(linked_lib, "**/*.rb")).each do |linked_feature|
    canonical_feature = File.realpath(linked_feature)
    next unless $LOADED_FEATURES.include?(linked_feature) || $LOADED_FEATURES.include?(canonical_feature)
    abort "Missing linked feature alias: #{linked_feature}" unless $LOADED_FEATURES.include?(linked_feature)
    abort "Missing canonical feature alias: #{canonical_feature}" unless $LOADED_FEATURES.include?(canonical_feature)
  end
  [linked_lib, canonical_lib].uniq.each do |root|
    require File.join(root, "redmine_mirror")
    require File.join(root, "redmine_mirror/hooks")
  end
' 2>&1) || { echo "$load_output" >&2; exit 1; }
if echo "$load_output" | grep "redmine_mirror" | grep "already initialized"; then
  echo "Redmine Mirror files were loaded twice" >&2
  exit 1
fi
for test_file in core_test client_test adapter_example_test ai_test diagnosis_test mirror_demo_test; do
  bundle exec ruby "plugins/redmine_mirror/test/$test_file.rb"
done
bundle exec rake db:migrate redmine:plugins:migrate
bundle exec rake redmine:plugins:migrate NAME=redmine_mirror VERSION=0
bundle exec rake redmine:plugins:migrate NAME=redmine_mirror
# Preserve browser evidence even if the plugin suite fails.
trap 'if [ -d tmp/screenshots ]; then cp -a tmp/screenshots/. /mirror-results/screenshots/; fi' EXIT
bundle exec rake redmine:plugins:test NAME=redmine_mirror
