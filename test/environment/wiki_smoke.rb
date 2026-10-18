# frozen_string_literal: true
# File: redmine_mirror/test/environment/wiki_smoke.rb
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
source_id = client.get("projects/mirror-wiki-demo.json").fetch("project").fetch("id")
alice = User.find_by!(login: "alice")
admin = User.find_by!(login: "admin")
project = Project.create!(name: "Wiki smoke", identifier: "wiki-smoke-#{SecureRandom.hex(4)}", is_public: true,
  enabled_module_names: %w[mirror wiki])
manager = Role.find_by!(name: "Manager")
[alice, admin].each { |user| Member.create!(project: project, user: user, roles: [manager]) }
page_path = ->(title, suffix = "") { "projects/#{source_id}/wiki/#{title}#{suffix}.json" }
execute = lambda do |setting, apply, expected = "succeeded"|
  run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: admin)
  RedmineMirror::Synchronization.execute(run)
  run.reload
  raise "Wiki run #{run.status}, expected #{expected}: #{run.error_message}" unless run.status == expected
  run
end
begin
  setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source_id)
  setting.api_key = original.api_key
  setting.selected_modules = %w[wiki]
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: source_id, adapters: setting.adapters).fetch
  setting.save!
  # Version 1 and 3 authors (Alice), the deleted version 2 is not listed; admin authors nothing visible.
  setting.source_catalog.fetch("user").each do |id, name|
    project.mirror_reference_mappings.create!(reference_type: "user", source_id: id, destination_id: (name.include?("Alice") ? alice : admin).id, mode: "existing")
  end
  execute.call(setting, false)
  raise "Preview wrote pages" if project.wiki.pages.exists?
  execute.call(setting, true)
  wiki = project.wiki.reload
  home = wiki.find_page("Wiki")
  child = wiki.find_page("Child_page")
  raise "Pages missing" unless home && child && wiki.pages.count == 2
  raise "Parent lost" unless child.parent_id == home.id
  source_home = client.get(page_path.call("Wiki")).fetch("wiki_page")
  raise "Version numbers lost" unless home.content.versions.order(:version).pluck(:version) == [1, 3] && home.content.version == 3
  raise "Version authors lost" unless home.content.versions.pluck(:author_id).uniq == [alice.id]
  raise "Version date lost" unless home.content.updated_on == Time.iso8601(source_home.fetch("updated_on"))
  raise "Page date lost" unless home.created_on == Time.iso8601(source_home.fetch("created_on"))
  raise "First version text lost" unless home.content.versions.find_by(version: 1).text.include?("First draft")
  raise "Attachment lost" unless child.attachments.map(&:filename) == ["wiki-note.txt"] && child.attachments.first.author_id == alice.id
  raise "Repeated wiki updates" unless execute.call(setting, true).log_events.all? { |event| event["action"] == "unchanged" }
  # A new source version is added as the next local version.
  client.update(page_path.call("Child_page"), "wiki_page" => { "text" => "Child content, second version.", "comments" => "Edited on the source" })
  # Its author (the source administrator) is new: refresh the references and map them.
  setting.update!(source_catalog: RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: source_id, adapters: setting.adapters).fetch)
  setting.source_catalog.fetch("user").each_key do |id|
    project.mirror_reference_mappings.find_or_create_by!(reference_type: "user", source_id: id) { |row| row.destination_id = admin.id; row.mode = "existing" }
  end
  execute.call(setting, true)
  child.reload
  source_version = client.get(page_path.call("Child_page")).fetch("wiki_page").fetch("version")
  raise "New source version not imported" unless child.content.text == "Child content, second version." && child.content.version == source_version
  # A local edit is a conflict; the page is kept as edited.
  child.content.text = "Local edit"
  child.content.save!
  execute.call(setting, true, setting.on_error == "skip" ? "partial" : "failed")
  raise "Local edit overwritten" unless child.reload.content.text == "Local edit"
  raise "Conflict not recorded" unless MirrorConflict.where(project_id: project.id, module_key: "wiki", status: "open").count == 1
  puts "Wiki smoke passed: preview, versions with gaps, authors, dates, parent, attachment, idempotence, new source version, local conflict"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  MirrorConflict.where(project_id: project.id).delete_all
  project.destroy!
end
