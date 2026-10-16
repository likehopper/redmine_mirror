# frozen_string_literal: true
# File: redmine_mirror/test/environment/history_smoke.rb
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
project = Project.create!(name: "History smoke", identifier: "history-smoke-#{SecureRandom.hex(4)}", enabled_module_names: %w[mirror issue_tracking time_tracking])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: original.source_project_id)
setting.api_key = original.api_key
setting.selected_modules = %w[issue_categories project_versions issue_journals issue_attachments time_tracking]
setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: setting.source_project_id, adapters: setting.adapters).fetch
setting.save!
original.project.mirror_reference_mappings.each do |row|
  project.mirror_reference_mappings.create!(reference_type: row.reference_type, source_id: row.source_id, destination_id: row.destination_id, mode: row.mode)
end
project.mirror_reference_mappings.find_or_create_by!(reference_type: "user", source_id: 1) { |row| row.mode = "anonymous" }
begin
  [false, true, true].each do |apply|
    run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: User.find_by!(login: "admin"))
    RedmineMirror::Synchronization.execute(run)
    run.reload
    abort "History import failed: #{run.error_message}" unless run.status == "succeeded"
    abort "Preview wrote issues" if !apply && project.issues.exists?
    puts "Run #{run.id}: #{run.status} #{run.module_counts.inspect}"
  end
  raise "Issue count" unless project.issues.count == 12
  source_issues = setting.source_client.each_record("issues", "project_id" => setting.source_project_id, "status_id" => "*", "subproject_id" => "!*").to_a
  source_issues.each do |source_issue|
    row = MirrorMapping.find_by!(project_id: project.id, module_key: "issue_tracking", source_id: source_issue.fetch("id"))
    imported = project.issues.find(row.destination_id)
    raise "Privacy lost" unless imported.is_private == source_issue.fetch("is_private")
    %w[created_on updated_on closed_on].each do |field|
      expected = source_issue[field] && Time.iso8601(source_issue[field])
      raise "Issue date lost: #{field}" unless imported.public_send(field) == expected
    end
    expected_author = source_issue.fetch("author").fetch("id") == 1 ? User.anonymous.id : User.find_by!(login: "alice").id
    raise "Issue author lost" unless imported.author_id == expected_author
  end
  # A reader without view_private_issues must not see imported private issues.
  reader_role = Role.create!(name: "Mirror reader #{SecureRandom.hex(3)}", permissions: [:view_issues])
  reader = User.create!(login: "reader-#{SecureRandom.hex(4)}", firstname: "Reader", lastname: "Mirror", mail: "reader-#{SecureRandom.hex(4)}@example.invalid", password: "Mirror-test-2026!", password_confirmation: "Mirror-test-2026!")
  Member.create!(project: project, user: reader, roles: [reader_role])
  raise "Private issues visible" if project.issues.where(is_private: true).any? { |issue| issue.visible?(reader) }
  raise "Public issues hidden" unless project.issues.where(is_private: false).all? { |issue| issue.visible?(reader) }
  journals = Journal.where(journalized: project.issues)
  raise "Journal count" unless journals.count == 36
  raise "Private notes lost" unless journals.where(private_notes: true).count == 12
  raise "Historical dates lost" unless journals.all? { |journal| journal.created_on.year == 2026 && journal.created_on.month == 1 }
  files = Attachment.where(container: project.issues)
  raise "Attachment count" unless files.count == 12
  raise "File contents lost" unless files.all? { |file| File.read(file.diskfile).include?("Mirror attachment fixture") }
  last = project.mirror_sync_runs.last
  raise "Not idempotent" unless last.log_events.all? { |event| event["action"] == "unchanged" }
  journal = journals.first
  previous_notes = journal.notes
  journal.update_columns(notes: "Local edit")
  conflict = RedmineMirror::Synchronization.enqueue(setting, apply: true, trigger: "operator", user: User.find_by!(login: "admin"))
  RedmineMirror::Synchronization.execute(conflict)
  raise "Local conflict not detected" unless conflict.reload.status == "failed" && conflict.error_message.include?("Local modification")
  journal.update_columns(notes: previous_notes)
  puts "History smoke passed: 36 dated journals, 12 private notes, 12 files, preview and idempotence"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  project.destroy!
  reader&.destroy!
  reader_role&.destroy!
end
