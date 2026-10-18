# frozen_string_literal: true
# File: redmine_mirror/test/environment/conflicts_demo.rb
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
# Build disposable demo records for manual and API synchronization checks.

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
original = Project.find_by!(identifier: "mirror-demo").mirror_project_setting
project = Project.create!(name: "Mirror conflicts demo", identifier: "conflict-demo-#{SecureRandom.hex(4)}", enabled_module_names: %w[mirror issue_tracking])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
  setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: original.source_project_id)
  setting.api_key = original.api_key
  setting.selected_modules = %w[issue_categories project_versions issue_tracking]
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: setting.source_project_id, adapters: setting.adapters).fetch
  setting.save!
  original.project.mirror_reference_mappings.each do |row|
    project.mirror_reference_mappings.create!(reference_type: row.reference_type, source_id: row.source_id, destination_id: row.destination_id, mode: row.mode) if setting.source_catalog.fetch(row.reference_type, {}).key?(row.source_id.to_s)
  end
  execute = lambda do |apply|
    run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: User.find_by!(login: "admin"))
    RedmineMirror::Synchronization.execute(run)
    run.reload
  end
  initial = execute.call(true)
  raise "Initial import failed: #{initial.error_message}" unless initial.status == "succeeded"
  # Introduce one genuine conflict at a time so normal stop-on-first-conflict
  # preflight records each object without changing that production behavior.
  originals = {}
  project.issues.order(:id).first(3).each do |issue|
    originals[issue.id] = issue.subject
    issue.update_columns(subject: "[Mirror conflict demo] #{issue.subject}")
    failed = execute.call(false)
    raise "Conflict not detected" unless failed.status == "failed"
    # Temporarily restore this object to let preflight reach the next one.
    issue.update_columns(subject: originals.fetch(issue.id))
  end
  originals.each { |id, subject| Issue.find(id).update_columns(subject: "[Mirror conflict demo] #{subject}") }
  File.write("/mirror-data/conflict-demo-#{project.id}.json", JSON.pretty_generate(originals))
  puts "Demo retained: http://localhost:3102/projects/#{project.identifier}/mirror?tab=conflicts"
  puts "Original subjects: /mirror-data/conflict-demo-#{project.id}.json"
  puts "#{project.mirror_conflicts.where(status: 'open').count} real conflicts, automatic synchronization disabled"
