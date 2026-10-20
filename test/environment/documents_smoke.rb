# frozen_string_literal: true
# File: redmine_mirror/test/environment/documents_smoke.rb
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
source_id = client.get("projects/mirror-documents-demo.json").fetch("project").fetch("id")
alice = User.find_by!(login: "alice")
admin = User.find_by!(login: "admin")
project = Project.create!(name: "Documents smoke", identifier: "documents-smoke-#{SecureRandom.hex(4)}", is_public: true,
  enabled_module_names: %w[mirror documents])
manager = Role.find_by!(name: "Manager")
[alice, admin].each { |user| Member.create!(project: project, user: user, roles: [manager]) }
execute = lambda do |setting, apply, expected = "succeeded"|
  run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: admin)
  RedmineMirror::Synchronization.execute(run)
  run.reload
  raise "Documents run #{run.status}, expected #{expected}: #{run.error_message}" unless run.status == expected
  run
end
begin
  setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source_id)
  setting.api_key = original.api_key
  setting.selected_modules = %w[documents]
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client(purpose: "references"), project_id: source_id, adapters: setting.adapters).fetch
  setting.save!
  setting.source_catalog.fetch("user").each do |id, name|
    project.mirror_reference_mappings.create!(reference_type: "user", source_id: id, destination_id: (name.include?("Alice") ? alice : admin).id, mode: "existing")
  end
  # Both instances load the same default categories: map them by name. An ignored category
  # leaves its documents out, logged as ignored.
  categories = setting.source_catalog.fetch("document_category").map do |id, name|
    project.mirror_reference_mappings.create!(reference_type: "document_category", source_id: id, mode: "ignore")
  end
  events = execute.call(setting, false).log_events
  raise "Ignored category: #{events.map { |event| event['action'] }}" unless events.size == 2 && events.all? { |event| event["action"] == "ignored" && event["reason"] == "Document category ignored by the mapping" }
  setting.source_catalog.fetch("document_category").each do |id, name|
    categories.find { |row| row.source_id == Integer(id) }.update!(mode: "existing", destination_id: DocumentCategory.find_by!(name: name).id)
  end
  execute.call(setting, false)
  raise "Preview wrote documents" if project.documents.exists?
  execute.call(setting, true)
  source_documents = client.get("projects/#{source_id}/mirror/source/documents.json").fetch("documents")
  documents = project.documents.reload.index_by(&:title)
  raise "Documents missing" unless documents.keys.sort == ["Architecture", "User guide"]
  architecture = documents.fetch("Architecture")
  source_architecture = source_documents.find { |document| document.fetch("title") == "Architecture" }
  raise "Category lost" unless architecture.category.name == "Technical documentation" && documents.fetch("User guide").category.name == "User documentation"
  raise "Date lost" unless architecture.created_on == Time.iso8601(source_architecture.fetch("created_on"))
  raise "Description lost" unless architecture.description.include?("components")
  files = architecture.attachments.order(:filename)
  raise "Files lost" unless files.map(&:filename) == %w[architecture.txt diagram.txt] && files.map(&:author_id) == [alice.id, admin.id]
  raise "File content lost" unless File.read(files.first.diskfile, encoding: "UTF-8") == "Architecture été\n"
  raise "File date lost" unless files.first.created_on == Time.iso8601(source_architecture.fetch("attachments").find { |file| file.fetch("filename") == "architecture.txt" }.fetch("created_on"))
  raise "Repeated document updates" unless execute.call(setting, true).log_events.all? { |event| event["action"] == "unchanged" }
  adapter = RedmineMirror::Adapters::Documents.new
  state = adapter.source_state(client, source_architecture.fetch("id"), architecture.id, source_project_id: source_id, project_id: project.id)
  raise "Source state #{state}" unless state == "present"
  # A local edit is a conflict; the document is kept as edited.
  architecture.update!(title: "Local title")
  execute.call(setting, true, setting.on_error == "skip" ? "partial" : "failed")
  raise "Local edit overwritten" unless architecture.reload.title == "Local title"
  raise "Conflict not recorded" unless MirrorConflict.where(project_id: project.id, module_key: "documents", status: "open").count == 1
  puts "Documents smoke passed: ignored category, preview, categories, dates, description, files with authors, idempotence, source state, local conflict"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  MirrorConflict.where(project_id: project.id).delete_all
  project.destroy!
end
