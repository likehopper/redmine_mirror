# frozen_string_literal: true
# File: redmine_mirror/test/environment/files_smoke.rb
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
# Exercise the Files module against the disposable Redmine environment.

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
original = Project.find_by!(identifier: "mirror-demo").mirror_project_setting
client = original.source_client
source_id = client.get("projects/mirror-files-demo.json").fetch("project").fetch("id")
alice = User.find_by!(login: "alice")
admin = User.find_by!(login: "admin")
project = Project.create!(name: "Files smoke", identifier: "files-smoke-#{SecureRandom.hex(4)}", is_public: true,
  enabled_module_names: %w[mirror files])
manager = Role.find_by!(name: "Manager")
[alice, admin].each { |user| Member.create!(project: project, user: user, roles: [manager]) }
execute = lambda do |setting, apply, expected = "succeeded"|
  run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: admin)
  RedmineMirror::Synchronization.execute(run)
  run.reload
  raise "Files run #{run.status}, expected #{expected}: #{run.error_message}" unless run.status == expected
  run
end
begin
  setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source_id)
  setting.api_key = original.api_key
  setting.selected_modules = %w[project_files]
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client(purpose: "references"), project_id: source_id, adapters: setting.adapters).fetch
  setting.save!
  setting.source_catalog.fetch("user").each do |id, name|
    project.mirror_reference_mappings.create!(reference_type: "user", source_id: id, destination_id: (name.include?("Alice") ? alice : admin).id, mode: "existing")
  end
  execute.call(setting, false)
  raise "Preview wrote files" if Attachment.where(container: [project] + project.versions.to_a).exists?
  # Counts before the import: Redmine counts Mirror's download of each file on the source.
  downloads = ->(files) { files.values.to_h { |file| [file.fetch("filename"), file.fetch("downloads").to_i] } }
  before = downloads.call(client.get("projects/#{source_id}/files.json").fetch("files").index_by { |file| file.fetch("filename") })
  execute.call(setting, true)
  source_files = client.get("projects/#{source_id}/files.json").fetch("files").index_by { |file| file.fetch("filename") }
  raise "Source counted more than one download per file" unless downloads.call(source_files) == before.transform_values { |count| count + 1 }
  # Exactly one of each (not `sole`: Redmine 5.1 runs Rails 6.1).
  only = ->(records) { records.to_a.tap { |list| raise "Expected one record, got #{list.size}" unless list.size == 1 }.first }
  version = only.call(project.versions.reload)
  installer = only.call(project.attachments.reload)
  notes = only.call(version.attachments)
  raise "Containers lost" unless [installer.filename, notes.filename, version.name] == ["installer.txt", "release-notes.txt", "1.0"]
  raise "Authors lost" unless [installer.author_id, notes.author_id] == [alice.id, admin.id]
  raise "File content lost" unless File.read(installer.diskfile, encoding: "UTF-8") == "Installer été\n"
  raise "File date lost" unless installer.created_on == Time.iso8601(source_files.fetch("installer.txt").fetch("created_on"))
  raise "Downloads lost" unless [installer.downloads, notes.downloads] == before.values_at("installer.txt", "release-notes.txt")
  raise "Repeated file updates" unless execute.call(setting, true).log_events.all? { |event| event["action"] == "unchanged" }
  adapter = RedmineMirror::Adapters::Files.new
  state = adapter.source_state(client, source_files.fetch("installer.txt").fetch("id"), installer.id, source_project_id: source_id, project_id: project.id)
  raise "Source state #{state}" unless state == "present"
  # A local edit is a conflict; the file is kept as edited.
  installer.update!(description: "Local description")
  execute.call(setting, true, setting.on_error == "skip" ? "partial" : "failed")
  raise "Local edit overwritten" unless installer.reload.description == "Local description"
  raise "Conflict not recorded" unless MirrorConflict.where(project_id: project.id, module_key: "project_files", status: "open").count == 1
  puts "Files smoke passed: preview, project and version files, authors, content, dates, downloads, idempotence, source state, local conflict"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  MirrorConflict.where(project_id: project.id).delete_all
  project.destroy!
end
