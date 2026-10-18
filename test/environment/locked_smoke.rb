# frozen_string_literal: true
# File: redmine_mirror/test/environment/locked_smoke.rb
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

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
original = Project.find_by!(identifier: "mirror-demo").mirror_project_setting
client = original.source_client
source_id = client.get("projects/mirror-locked-demo.json").fetch("project").fetch("id")
alice = User.find_by!(login: "alice")
admin = User.find_by!(login: "admin")
leaver = User.find_by(login: "mirror-leaver") || User.create!(login: "mirror-leaver", firstname: "Lea", lastname: "Leaver",
  mail: "mirror-leaver@example.invalid", password: "Mirror-test-2026!", password_confirmation: "Mirror-test-2026!")
# Redmine only adds active accounts as members: add the leaver, then lock the account.
leaver.update!(status: User::STATUS_ACTIVE)
project = Project.create!(name: "Locked smoke", identifier: "locked-smoke-#{SecureRandom.hex(4)}", is_public: true,
  enabled_module_names: %w[mirror issue_tracking time_tracking])
project.trackers = Tracker.all
manager = Role.find_by!(name: "Manager")
[alice, admin, leaver].each { |user| Member.create!(project: project, user: user, roles: [manager]) }
leaver.lock!
begin
  raise "Locked member not offered" unless RedmineMirror::MappingTable.new("user").local_records(project).include?(leaver)
  setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source_id)
  setting.api_key = original.api_key
  setting.selected_modules = %w[project_versions issue_tracking time_tracking issue_journals issue_watchers]
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: source_id, adapters: setting.adapters).fetch
  setting.save!
  models = { "tracker" => Tracker, "status" => IssueStatus, "priority" => IssuePriority, "activity" => TimeEntryActivity }
  setting.source_catalog.each do |kind, values|
    next unless (models.keys + ["user"]).include?(kind)
    values.each do |id, name|
      target = if kind == "user"
        { "Lea Leaver" => leaver, "Alice Mirror" => alice }.fetch(name, admin).id
      else
        models.fetch(kind).find_by!(name: name).id
      end
      project.mirror_reference_mappings.create!(reference_type: kind, source_id: id, destination_id: target, mode: "existing")
    end
  end
  runs = [false, true, true].map do |apply|
    run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: admin)
    RedmineMirror::Synchronization.execute(run)
    run.reload
    raise "Locked import failed: #{run.error_message}" unless run.status == "succeeded"
    raise "Preview wrote issues" if !apply && project.issues.exists?
    run
  end
  issue = project.issues.find_by!(subject: "Mirror issue of a user who left")
  raise "Locked author lost" unless issue.author_id == leaver.id
  raise "Locked assignee lost" unless issue.assigned_to_id == leaver.id
  raise "Closed version lost" unless issue.fixed_version&.name == "Mirror shipped release" && issue.fixed_version.status == "closed"
  raise "Locked journal author lost" unless issue.journals.where(notes: "Note by a user who left").pluck(:user_id) == [leaver.id]
  raise "Locked time entry user lost" unless project.time_entries.pluck(:user_id) == [leaver.id]
  watchers = issue.watcher_users.pluck(:id)
  raise "Locked watcher subscribed" if watchers.include?(leaver.id)
  raise "Active watcher missing" unless watchers.include?(alice.id)
  raise "Repeated updates" unless runs.last.log_events.all? { |event| %w[unchanged ignored].include?(event["action"]) }
  puts "Locked smoke passed: locked author, assignee, journal and time entry kept, closed version, locked watcher skipped, idempotent rerun"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  project.destroy!
end
