# frozen_string_literal: true
# File: redmine_mirror/test/environment/conflicts_smoke.rb
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
project = Project.create!(name: "Conflicts smoke", identifier: "conflict-smoke-#{SecureRandom.hex(4)}", enabled_module_names: %w[mirror issue_tracking])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
begin
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
  issue = project.issues.order(:id).first
  original_subject = issue.subject
  issue.update_columns(subject: "Retained local subject")
  failed = execute.call(false)
  # Skip mode (default): the preview reads as partial, the conflicting issue excluded.
  raise "Conflict not captured" unless failed.status == "partial" && project.mirror_conflicts.count == 1
  conflict = project.mirror_conflicts.first!
  raise "Wrong conflict identity" unless conflict.module_key == "issue_tracking" && conflict.destination_id == issue.id
  mapping = MirrorMapping.find_by!(connection_key: conflict.connection_key, module_key: conflict.module_key, source_id: conflict.source_id)
  previous_fingerprint = mapping.destination_fingerprint
  conflict.update!(status: "ignored", resolved_by: User.find_by!(login: "admin"))
  continued = execute.call(true)
  raise "Excluded conflict still blocks" unless continued.status == "succeeded"
  raise "Local subject overwritten" unless issue.reload.subject == "Retained local subject"
  raise "Mapping changed" unless mapping.reload.destination_fingerprint == previous_fingerprint
  raise "Exclusion not logged" unless continued.log_events.any? { |event| event["source_id"] == conflict.source_id && event["module"] == conflict.module_key && event["action"] == "ignored" }
  conflict.update!(status: "open")
  repeated = execute.call(false)
  raise "Recheck bypassed conflict" unless repeated.status == "partial"
  raise "Duplicate conflicts" unless project.mirror_conflicts.count == 1
  issue.update_columns(subject: original_subject)
  corrected = execute.call(true)
  raise "Correction failed" unless corrected.status == "succeeded" && conflict.reload.status == "resolved"
  puts "Conflicts smoke passed: detection, retained local object, mapping preservation, exclusion log, recheck and correction"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  project.destroy!
end
