# frozen_string_literal: true
# File: redmine_mirror/test/environment/mirror_mode_smoke.rb
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

require "net/http"
require "timeout"

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
original = Project.find_by!(identifier: "mirror-demo").mirror_project_setting
client = original.source_client
admin = User.find_by!(login: "admin")
# Mirror's client never deletes; this check deletes source issues it created itself.
delete_source = lambda do |path|
  uri = URI.join(original.source_url.sub(%r{/*\z}, "/"), path)
  request = Net::HTTP::Delete.new(uri)
  request["X-Redmine-API-Key"] = original.api_key
  response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  raise "Source deletion failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
end
source_issue = ->(subject) { client.create("issues.json", "issue" => { "project_id" => original.source_project_id, "subject" => subject, "tracker_id" => 1 }).fetch("issue").fetch("id") }
project = Project.create!(name: "Mirror mode smoke", identifier: "mirror-mode-#{SecureRandom.hex(4)}", enabled_module_names: %w[mirror issue_tracking time_tracking])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: original.source_project_id, source_wins: true)
setting.api_key = original.api_key
setting.selected_modules = %w[issue_categories project_versions issue_tracking time_tracking issue_journals]
setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: setting.source_project_id, adapters: setting.adapters).fetch
setting.save!
original.project.mirror_reference_mappings.each do |row|
  project.mirror_reference_mappings.create!(reference_type: row.reference_type, source_id: row.source_id, destination_id: row.destination_id, mode: row.mode)
end
execute = lambda do |confirm = false|
  run = RedmineMirror::Synchronization.enqueue(setting, apply: true, trigger: "operator", user: admin, confirm_deletions: confirm)
  RedmineMirror::Synchronization.execute(run)
  # The environment's worker may claim the run first: wait for its end either way.
  Timeout.timeout(600) { sleep 2 while %w[queued running].include?(run.reload.status) }
  run
end
local = ->(source_id) { project.issues.find_by(id: MirrorMapping.find_by(project_id: project.id, module_key: "issue_tracking", source_id: source_id)&.destination_id) }
extra = []
note_id = note_text = nil
begin
  first_run = execute.call
  raise "First import #{first_run.status}: #{first_run.error_message}" unless project.issues.count == 12
  first = client.each_record("issues", "project_id" => original.source_project_id, "status_id" => "*", "sort" => "id:asc").first
  journal = client.get("issues/#{first['id']}.json", "include" => "journals").fetch("issue").fetch("journals").find { |row| row["notes"].present? }
  note_id, note_text = journal.fetch("id"), journal.fetch("notes")
  # Local edits and a local deletion are overwritten and recreated.
  local.call(first["id"]).update_columns(subject: "Local subject")
  local_journal = Journal.find(MirrorMapping.find_by!(project_id: project.id, module_key: "issue_journals", source_id: note_id).destination_id)
  local_journal.update_columns(notes: "Local note")
  second = client.each_record("issues", "project_id" => original.source_project_id, "status_id" => "*", "sort" => "id:asc").to_a[1]
  local.call(second["id"]).destroy
  run = execute.call
  raise "Overwrite run #{run.status}: #{run.error_message}" unless run.status == "succeeded"
  raise "Local subject kept" unless local.call(first["id"]).subject == first["subject"]
  raise "Local note kept" unless Journal.find_by(id: local_journal.id)&.notes == note_text
  raise "Deleted issue not recreated" unless local.call(second["id"]) && project.issues.count == 12
  # A note edited on the source is updated in place (journal API: Redmine 5.0 and later;
  # older sources answer 403 or 404).
  edited = begin
    client.update("journals/#{note_id}.json", "journal" => { "notes" => "Edited on the source" })
  rescue RedmineMirror::Error => error
    raise unless error.message.match?(/HTTP 40[34]/)
    note_id = nil
  end
  if edited
    execute.call
    raise "Source note edit not applied" unless Journal.find(local_journal.id).notes == "Edited on the source"
  end
  # Source deletions: two pass (limit), five wait for a confirmation.
  extra = (1..7).map { |index| source_issue.call("Mirror mode extra #{index}") }
  execute.call
  raise "Extra issues not imported" unless project.issues.count == 19
  extra.first(2).each { |id| delete_source.call("issues/#{id}.json") }
  execute.call
  raise "Two deletions not propagated" unless project.issues.count == 17
  extra.last(5).each { |id| delete_source.call("issues/#{id}.json") }
  blocked = execute.call
  raise "Deletions beyond the limit applied" unless project.issues.count == 17 && blocked.status == "partial"
  raise "Blocked deletions not reported" unless blocked.log_events.count { |event| event["reason"].to_s.start_with?("Deletion awaits confirmation") } == 5
  confirmed = execute.call(true)
  raise "Confirmed deletions not applied: #{confirmed.error_message}" unless project.issues.count == 12 && confirmed.status == "succeeded"
  extra = []
  last = execute.call
  raise "Repeated updates" unless last.log_events.all? { |event| event["action"] == "unchanged" }
  puts "Mirror mode smoke passed: local edits overwritten, local deletion recreated, source note edit applied, deletions limited then confirmed, idempotence"
ensure
  client.update("journals/#{note_id}.json", "journal" => { "notes" => note_text }) if note_id
  extra.each { |id| delete_source.call("issues/#{id}.json") rescue nil }
  MirrorMapping.where(project_id: project.id).delete_all
  project.destroy!
end
