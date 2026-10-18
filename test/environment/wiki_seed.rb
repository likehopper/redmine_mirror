# frozen_string_literal: true
# File: redmine_mirror/test/environment/wiki_seed.rb
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
admin = User.find_by!(login: "admin")
alice = User.find_by!(login: "alice")
User.current = admin
project = Project.find_or_create_by!(identifier: "mirror-wiki-demo") do |row|
  row.name = "Mirror wiki fixtures"
  row.enabled_module_names = %w[wiki]
end
Member.find_or_create_by!(project: project, user: alice) { |row| row.roles = [Role.find_by!(name: "Manager")] }
wiki = project.wiki || Wiki.create!(project: project, start_page: "Wiki")
unless wiki.find_page("Wiki")
  page = wiki.pages.new(title: "Wiki")
  # Three versions by two authors; the second is deleted, leaving a gap.
  [[alice, "h1. Home\n\nFirst draft.", "Created"], [admin, "h1. Home\n\nSecond draft.", "Admin edit"],
    [alice, "h1. Home\n\nSee [[Child_page]] and *bold* text.", "Final"]].each_with_index do |(author, text, comments), index|
    content = page.content || WikiContent.new
    content.assign_attributes(text: text, comments: comments, author: author)
    page.new_record? ? (page.content = content; page.save!) : content.save!
    content.versions.find_by!(version: content.version).update_columns(updated_on: Time.utc(2026, 1, 10 + index, 9))
    content.update_columns(updated_on: Time.utc(2026, 1, 10 + index, 9))
  end
  page.update_columns(created_on: Time.utc(2026, 1, 10, 9))
  page.content.versions.find_by!(version: 2).destroy
  child = wiki.pages.new(title: "Child_page", parent: page)
  child.content = WikiContent.new(text: "Child content by Alice.", author: alice, comments: "Child")
  child.save!
  attachment = child.attachments.new(author: alice, description: "Wiki attachment")
  Tempfile.create(["wiki-note", ".txt"]) do |file|
    file.write("Wiki file été\n")
    file.rewind
    attachment.file = file
    attachment.filename = "wiki-note.txt"
    attachment.content_type = "text/plain"
    attachment.save!
  end
end
puts "Wiki fixtures ready: start page with versions 1 and 3 (2 deleted), two authors, fixed dates; child page with an attachment"
