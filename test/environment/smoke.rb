# frozen_string_literal: true
# File: redmine_mirror/test/environment/smoke.rb
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
# Exercise Mirror behavior against the disposable Redmine environment.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
config = JSON.parse(File.read(ENV.fetch("MIRROR_CONFIG")))
if ENV["MIRROR_PROJECT_CONFIG_SMOKE"] == "1"
  manual = Project.find_by!(identifier: "mirror-demo")
  setting = manual.mirror_project_setting
  abort "Configure Mirror in the manual project first" unless setting
  config = setting.synchronization_config(destination_url: config.fetch("destination_url"))
  source_key = setting.api_key
else
  source_key = ENV.fetch("MIRROR_SOURCE_API_KEY")
end
project = Project.create!(name: "Mirror API smoke", identifier: "mirror-smoke-#{SecureRandom.hex(4)}",
  enabled_module_names: %w[issue_tracking time_tracking mirror])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
config["destination_project_id"] = project.id
config["modules"] = %w[issue_categories project_versions issue_tracking time_tracking]
key = Digest::SHA256.hexdigest("disposable-smoke-#{project.id}")
source = RedmineMirror::Client.new(url: config.fetch("source_url"), api_key: source_key, allow_http: true)
destination = RedmineMirror::Client.new(url: config.fetch("destination_url"), api_key: ENV.fetch("MIRROR_DESTINATION_API_KEY"), allow_http: true)
runner = RedmineMirror::Runner.new(source: source, destination: destination, store: RedmineMirror::DatabaseStore.new(key))
begin
  preview = runner.run(config)
  abort "Wrong preview count" unless preview.size == 27
  abort "Preview wrote data" unless project.issues.count.zero? && project.time_entries.count.zero? && MirrorMapping.where(connection_key: key).count.zero?
  runner.run(config, apply: true)
  abort "Wrong imported counts" unless project.issues.count == 12 && project.time_entries.count == 13
  abort "Wrong mappings count" unless MirrorMapping.where(connection_key: key).count == 27
  abort "Import is not idempotent" unless runner.run(config, apply: true).all? { |row| row[:action] == "unchanged" }
  project.issues.first.update!(subject: "Local smoke conflict")
  begin
    runner.run(config)
    abort "Local conflict was not detected"
  rescue RedmineMirror::Error => error
    raise unless error.message.include?("Local modification")
  end
  puts "API smoke passed: preview, 12 issues, 13 time entries, 27 persisted mappings, idempotence and conflict detection"
ensure
  project.destroy!
  MirrorMapping.where(connection_key: key).delete_all
end
