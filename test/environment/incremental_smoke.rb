# frozen_string_literal: true
# File: redmine_mirror/test/environment/incremental_smoke.rb
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

# End-to-end incremental protocol: a partial baseline reports failed objects to the
# source, adding their missing mapping retries only them, then one issue change is
# proposed and acknowledged exactly once.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
config = JSON.parse(File.read(ENV.fetch("MIRROR_CONFIG")))
project = Project.create!(name: "Incremental smoke", identifier: "incremental-smoke-#{SecureRandom.hex(4)}",
  enabled_module_names: %w[mirror issue_tracking time_tracking])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
setting = MirrorProjectSetting.new(project: project, source_url: config.fetch("source_url"),
  source_project_id: config.fetch("source_project_id"), on_error: "skip")
setting.selected_modules = config.fetch("modules")
setting.api_key = ENV.fetch("MIRROR_SOURCE_API_KEY")
setting.source_catalog = {}
setting.module_options = {}
setting.save!

# Activity 8 is intentionally absent from the first complete pass. Test fixture rows are
# already validated by the ordinary UI smoke; bypass only the catalog-dependent form
# validation while constructing this isolated project's identical mappings.
config.fetch("mappings").each do |kind, rows|
  rows.each do |source_id, destination_id|
    next if kind == "activity" && source_id == "8"
    row = project.mirror_reference_mappings.new(reference_type: kind, source_id: source_id,
      destination_id: destination_id, mode: "existing")
    row.save!(validate: false)
  end
end

run = lambda do
  execution = RedmineMirror::Synchronization.enqueue(setting, apply: true, trigger: "operator", user: User.find_by!(login: "admin"))
  RedmineMirror::Synchronization.execute(execution)
  execution.reload
end

begin
  baseline = run.call
  abort "Expected a partial baseline, got #{baseline.status}: #{baseline.error_message}" unless baseline.status == "partial"
  failed_time_ids = baseline.log_events.select { |event| event["module"] == "time_tracking" && event["action"] == "error" }.map { |event| event["source_id"] }
  abort "Missing activity did not retain time entries" if failed_time_ids.empty?
  abort "Baseline did not persist a source cursor" unless setting.reload.source_change_cursor

  activity = project.mirror_reference_mappings.new(reference_type: "activity", source_id: 8,
    destination_id: config.dig("mappings", "activity", "8"), mode: "existing")
  activity.save!(validate: false)
  retried = run.call
  abort "Retry failed: #{retried.status}: #{retried.error_message}" unless retried.status == "succeeded"
  retried_time_ids = retried.log_events.select { |event| event["module"] == "time_tracking" }.map { |event| event["source_id"] }
  abort "Retry scanned unrelated time entries" unless retried_time_ids.sort == failed_time_ids.sort
  abort "Retry scanned unchanged issues" if retried.log_events.any? { |event| event["module"] == "issue_tracking" }
  abort "Retry queue was not cleared" unless MirrorSyncRetry.where(project_id: project.id).none?
  abort "Time import stayed incomplete" unless project.time_entries.count == 13

  source = setting.source_client(purpose: "synchronization")
  source_issue = source.each_record("issues", "project_id" => setting.source_project_id,
    "status_id" => "*", "sort" => "id:asc").first
  source.update("issues/#{source_issue.fetch('id')}.json",
    "issue" => { "subject" => "Incremental #{SecureRandom.hex(4)}" })
  changed = run.call
  issue_events = changed.log_events.select { |event| event["module"] == "issue_tracking" }
  abort "Changed issue was not synchronized alone: #{issue_events.inspect}" unless issue_events.size == 1 && issue_events.first["source_id"] == source_issue.fetch("id")
  abort "Issue change scanned time entries" if changed.log_events.any? { |event| event["module"] == "time_tracking" }

  acknowledged = run.call
  if acknowledged.log_events.any? { |event| %w[issue_tracking time_tracking].include?(event["module"]) }
    abort "Acknowledged core object was proposed again"
  end
  puts "Incremental smoke passed: partial baseline, mapping-only retry, one issue change acknowledged once, unchanged core collections skipped"
ensure
  project.destroy!
end
