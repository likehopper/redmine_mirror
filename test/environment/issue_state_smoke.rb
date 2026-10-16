# frozen_string_literal: true
# File: redmine_mirror/test/environment/issue_state_smoke.rb
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
previous_subtasks = Setting.cross_project_subtasks
Setting.cross_project_subtasks = "system"
created = []
settings = {}
client = original.source_client
source_ids = %w[mirror-state-demo mirror-state-child-a mirror-state-child-b mirror-state-independent].to_h do |identifier|
  [identifier, client.get("projects/#{identifier}.json").fetch("project").fetch("id")]
end
begin
  source_ids.each do |identifier, source_id|
    project = Project.create!(name: identifier, identifier: "state-smoke-#{SecureRandom.hex(5)}", is_public: true, enabled_module_names: %w[mirror issue_tracking])
    created << project
    project.trackers = Tracker.all
    Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
    Member.create!(project: project, user: User.find_by!(login: "admin"), roles: [Role.find_by!(name: "Manager")])
    setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source_id)
    setting.api_key = original.api_key
    setting.selected_modules = %w[issue_hierarchy issue_watchers]
    setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: source_id, adapters: setting.adapters).fetch
    setting.save!
    setting.source_catalog.each do |kind, values|
      next unless %w[tracker status priority user].include?(kind)
      values.each do |id, name|
        target = if kind == "user"
          name.include?("Alice") ? User.find_by!(login: "alice").id : User.find_by!(login: "admin").id
        else
          { "tracker" => Tracker, "status" => IssueStatus, "priority" => IssuePriority }.fetch(kind).find_by!(name: name).id
        end
        project.mirror_reference_mappings.create!(reference_type: kind, source_id: id, destination_id: target, mode: "existing")
      end
    end
    settings[identifier] = setting
  end
  execute = lambda do |setting, apply|
    run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: User.find_by!(login: "admin"))
    RedmineMirror::Synchronization.execute(run)
    raise "Import failed: #{run.reload.error_message}" unless run.status == "succeeded"
    run
  end
  first = settings.fetch("mirror-state-child-b")
  execute.call(first, false)
  raise "Preview wrote issues" if first.project.issues.exists?
  initial = execute.call(first, true)
  raise "Pending parent not recorded" unless first.project.mirror_pending_parents.where(status: "pending").count == 1
  raise "Missing deferred parent" unless initial.log_events.any? { |event| event["module"] == "issue_hierarchy" && event["action"] == "ignored" }
  settings.each_value { |setting| execute.call(setting, true) }
  settings.each_value { |setting| execute.call(setting, true) }
  raise "Resolved parent still pending" if first.project.mirror_pending_parents.exists?
  raise "Unmirrored parent not retained" unless settings.fetch("mirror-state-child-a").project.mirror_pending_parents.count == 1
  settings.each do |identifier, setting|
    sources = RedmineMirror::Adapters::Watchers.new.records(client, setting.source_project_id).to_a
    sources.each do |source|
      mapping = MirrorMapping.find_by!(project_id: setting.project_id, module_key: "issue_tracking", source_id: source.fetch("id"))
      issue = Issue.find(mapping.destination_id)
      if source["parent"]
        parent_row = MirrorMapping.where(project_id: created.map(&:id), module_key: "issue_tracking", source_id: source["parent"]["id"]).first
        raise "Parent mismatch" unless issue.parent_id == parent_row&.destination_id
      end
      if source.fetch("watchers").size == 2
        raise "External observer missing" unless issue.watcher_users.pluck(:id).sort == [User.find_by!(login: "alice").id, User.find_by!(login: "admin").id].sort
      end
    end
    last = execute.call(setting, true)
    raise "Repeated updates" unless last.log_events.all? { |event| %w[unchanged ignored].include?(event["action"]) }
  end
  puts "Hierarchy/watchers smoke passed: preview, cross-project second pass, missing parent, outsider catalog, idempotence"
ensure
  # Unlink nested sets before destroying projects with cross-project children.
  Issue.where(project_id: created.map(&:id)).each { |issue| issue.parent_issue_id = nil; issue.save! }
  MirrorMapping.where(project_id: created.map(&:id)).delete_all
  created.reverse_each(&:destroy!)
  Setting.cross_project_subtasks = previous_subtasks
end
