# frozen_string_literal: true
# File: redmine_mirror/test/environment/enrich_source.rb
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

abort "Disposable source environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
Attachment.storage_path = "/mirror-data/files"
project = Project.find_by!(identifier: "mirror-demo")
alice = User.find_by!(login: "alice")
admin = User.find_by!(login: "admin")
open_status = IssueStatus.where(is_closed: false).order(:id).first!
closed_status = IssueStatus.where(is_closed: true).order(:id).first!
project.issues.order(:id).each_with_index do |issue, index|
  # Stable fixture markers allow rerunning this script without duplicating history.
  [
    ["Mirror fixture: public note", alice, false, nil],
    ["Mirror fixture: private note", admin, true, nil],
    ["Mirror fixture: status changed", alice, false, [open_status.id, closed_status.id]]
  ].each_with_index do |(notes, author, private_notes, status_change), position|
    next if issue.journals.exists?(notes: notes)
    Journal.transaction do
      journal = Journal.create!(journalized: issue, user: author, notes: notes,
        private_notes: private_notes, created_on: Time.utc(2026, 1, 1, 10) + index.days + position.hours)
      if status_change
        journal.details.create!(property: "attr", prop_key: "status_id",
          old_value: status_change.first.to_s, value: status_change.last.to_s)
        issue.update_columns(status_id: closed_status.id, done_ratio: 100)
      end
    end
  end
  issue.update_columns(author_id: (index == 11 ? admin.id : alice.id), is_private: index.even?,
    created_on: Time.utc(2025, 12, 1, 9) + index.days,
    updated_on: Time.utc(2026, 1, 1, 12) + index.days,
    closed_on: Time.utc(2026, 1, 1, 12) + index.days)
  next if issue.attachments.exists?(filename: "mirror-note.txt")
  File.open("/mirror-environment/fixtures/mirror-note.txt", "rb") do |file|
    Attachment.create!(container: issue, author: alice, file: file,
      filename: "mirror-note.txt", content_type: "text/plain", description: "Mirror fixture attachment")
  end
end
puts "Enriched source: #{project.issues.count} issues, #{Journal.where(journalized: project.issues).count} journals, #{Attachment.where(container: project.issues).count} attachments"

load "/mirror-environment/relations_seed.rb"
load "/mirror-environment/references_seed.rb"
