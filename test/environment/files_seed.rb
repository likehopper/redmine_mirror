# frozen_string_literal: true
# File: redmine_mirror/test/environment/files_seed.rb
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
# Build disposable project files (Files module) for the Files module checks.

abort "Disposable source only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
admin = User.find_by!(login: "admin")
alice = User.find_by!(login: "alice")
User.current = admin
project = Project.find_or_create_by!(identifier: "mirror-files-demo") do |row|
  row.name = "Mirror files fixtures"
  row.enabled_module_names = %w[files]
end
Member.find_or_create_by!(project: project, user: alice) { |row| row.roles = [Role.find_by!(name: "Manager")] }
version = project.versions.find_or_create_by!(name: "1.0")
unless Attachment.where(container: [project, version]).exists?
  # One file on the project, one on the version, at fixed dates with download counts.
  [[project, alice, "installer.txt", "Installer été\n", "Installer", Time.utc(2026, 3, 4, 9), 12],
    [version, admin, "release-notes.txt", "Release notes\n", "", Time.utc(2026, 3, 5, 9), 3]].each do |container, author, filename, content, description, created_on, downloads|
    attachment = container.attachments.new(author: author, description: description)
    Tempfile.create([File.basename(filename, ".txt"), ".txt"]) do |file|
      file.write(content)
      file.rewind
      attachment.file = file
      attachment.filename = filename
      attachment.content_type = "text/plain"
      attachment.save!
    end
    attachment.update_columns(created_on: created_on, downloads: downloads)
  end
end
puts "Files fixtures ready: installer.txt on the project (Alice, 12 downloads) and release-notes.txt on version 1.0 (admin, 3 downloads), fixed dates"
