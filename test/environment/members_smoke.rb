# frozen_string_literal: true
# File: redmine_mirror/test/environment/members_smoke.rb
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
source_id = client.get("projects/mirror-members-demo.json").fetch("project").fetch("id")
admin = User.find_by!(login: "admin")
alice = User.find_by!(login: "alice")
leaver = User.find_by(login: "mirror-leaver") || User.create!(login: "mirror-leaver", firstname: "Lea", lastname: "Leaver",
  mail: "mirror-leaver@example.invalid", password: "Mirror-test-2026!", password_confirmation: "Mirror-test-2026!")
leaver.lock! unless leaver.locked?
group = Group.find_by(lastname: "Mirror team") || Group.create!(lastname: "Mirror team")
project = Project.create!(name: "Members smoke", identifier: "members-smoke-#{SecureRandom.hex(4)}", enabled_module_names: %w[mirror issue_tracking])
manager = Role.find_by!(name: "Manager")
Member.create!(project: project, user: admin, roles: [manager])
execute = lambda do |setting, apply|
  run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: admin)
  RedmineMirror::Synchronization.execute(run)
  run.reload
  raise "Members run #{run.status}: #{run.error_message}" unless run.status == "succeeded"
  run
end
begin
  setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source_id)
  setting.api_key = original.api_key
  setting.selected_modules = %w[project_members]
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: source_id, adapters: setting.adapters).fetch
  setting.save!
  # A members manager chooses among all accounts: Alice and the locked leaver are not members yet.
  User.current = admin
  choices = RedmineMirror::MappingTable.new("user").local_records(project.reload)
  raise "Accounts outside the project not offered" unless choices.include?(alice) && choices.include?(leaver)
  # Mappings are saved by that members manager, as in the Users tab.
  { "user" => { "Alice Mirror" => alice, "Lea Leaver" => leaver }, "group" => { "Mirror team" => group } }.each do |kind, targets|
    setting.source_catalog.fetch(kind).each do |id, name|
      project.mirror_reference_mappings.create!(reference_type: kind, source_id: id, destination_id: targets.fetch(name).id, mode: "existing")
    end
  end
  setting.source_catalog.fetch("role").each do |id, name|
    project.mirror_reference_mappings.create!(reference_type: "role", source_id: id, destination_id: Role.find_by!(name: name).id, mode: "existing")
  end
  User.current = nil
  execute.call(setting, false)
  raise "Preview added members" unless project.memberships.count == 1
  execute.call(setting, true)
  roles = ->(principal) { project.memberships.find_by(user_id: principal.id)&.roles&.map(&:name) }
  raise "Alice not added" unless roles.call(alice) == ["Manager"]
  raise "Locked leaver not added" unless roles.call(leaver) == ["Reporter"]
  raise "Group not added" unless roles.call(group) == ["Developer"]
  raise "Admin membership changed" unless roles.call(admin) == ["Manager"]
  last = execute.call(setting, true)
  raise "Repeated member updates" unless last.log_events.all? { |event| %w[unchanged ignored].include?(event["action"]) }
  puts "Members smoke passed: accounts outside the project offered, preview, user, locked user and group added with mapped roles, idempotence"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  project.destroy!
end
