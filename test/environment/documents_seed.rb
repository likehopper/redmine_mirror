# frozen_string_literal: true
# File: redmine_mirror/test/environment/documents_seed.rb
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

abort "Disposable source only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
abort "Install Redmine Mirror on the source (MIRROR_SOURCE_PLUGIN=1)" unless defined?(RedmineMirror)
admin = User.find_by!(login: "admin")
alice = User.find_by!(login: "alice")
User.current = admin
project = Project.find_or_create_by!(identifier: "mirror-documents-demo") do |row|
  row.name = "Mirror documents fixtures"
  row.enabled_module_names = %w[documents mirror_source]
end
# Mirror source: allowed by the administrator, module enabled, documents shared.
Setting.plugin_redmine_mirror = Setting.plugin_redmine_mirror.to_h.merge("source_enabled" => "1")
project.enable_module!(:mirror_source)
(project.mirror_source_setting || project.build_mirror_source_setting).update!(shared_modules: %w[documents])
Member.find_or_create_by!(project: project, user: alice) { |row| row.roles = [Role.find_by!(name: "Manager")] }
unless project.documents.exists?
  technical = DocumentCategory.find_by!(name: "Technical documentation")
  user_docs = DocumentCategory.find_by!(name: "User documentation")
  # Two documents at fixed dates; the first has two files by two authors.
  [[technical, "Architecture", "h2. Overview\n\nSee *components*.", Time.utc(2026, 2, 3, 10), [[alice, "architecture.txt", "Architecture été\n"], [admin, "diagram.txt", "Diagram\n"]]],
    [user_docs, "User guide", "", Time.utc(2026, 2, 4, 10), []]].each do |category, title, description, created_on, files|
    document = project.documents.create!(category: category, title: title, description: description)
    document.update_columns(created_on: created_on)
    files.each_with_index do |(author, filename, content), index|
      attachment = document.attachments.new(author: author, description: "File #{index + 1}")
      Tempfile.create([File.basename(filename, ".txt"), ".txt"]) do |file|
        file.write(content)
        file.rewind
        attachment.file = file
        attachment.filename = filename
        attachment.content_type = "text/plain"
        attachment.save!
      end
      attachment.update_columns(created_on: created_on + (index + 1) * 60)
    end
  end
end
puts "Documents fixtures ready: Architecture (technical, two files by Alice and admin) and User guide (user documentation, no file), fixed dates; shared through Mirror source"
