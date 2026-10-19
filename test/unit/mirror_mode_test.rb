# frozen_string_literal: true
# File: redmine_mirror/test/unit/mirror_mode_test.rb
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
# Verify Mirror behavior, project boundaries and repeatable synchronization.

require_relative "../test_helper"

class MirrorModeTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :issues, :issue_statuses, :trackers,
    :enumerations, :enabled_modules, :versions, :journals, :journal_details, :watchers

  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
    def delete(key, id); @rows.delete([key, id]); end
  end

  def setup
    @store = Store.new
    @issue = Issue.find(1)
    @lookup = ->(key, id) { key == "issue_tracking" && id == 900 ? @issue.id : nil }
    @mappings = { "user" => { "7" => "2", "8" => "3" } }
  end

  def mirror(source_wins: false, &block)
    RedmineMirror::Policy.with(source_wins: source_wins, &block)
  end

  def note(text)
    { "id" => 500, "issue_id" => 900, "project" => { "id" => 9 }, "user" => { "id" => 7 },
      "created_on" => "2026-01-05T10:00:00Z", "notes" => text, "private_notes" => false, "details" => [] }
  end

  def sync_note(record, source_wins: false)
    mirror(source_wins: source_wins) do
      RedmineMirror::Adapters::Journals.new.synchronize(record, project_id: @issue.project_id, mappings: @mappings,
        lookup: @lookup, store: @store, source: nil, apply: true)
    end
  end

  def test_note_edited_on_the_source_is_updated_in_place
    created = sync_note(note("First text"))
    assert_equal "update", sync_note(note("Edited on the source"))[:action]
    journal = Journal.find(created[:destination_id])
    assert_equal ["Edited on the source", 2], [journal.notes, journal.user_id]
    assert_equal "unchanged", sync_note(note("Edited on the source"))[:action]
  end

  def test_local_note_edit_is_a_conflict_or_overwritten_when_the_source_wins
    journal = Journal.find(sync_note(note("Source text"))[:destination_id])
    journal.update_columns(notes: "Local edit")
    assert_raises(RedmineMirror::Error) { sync_note(note("Source text")) }
    assert_equal "update", sync_note(note("Source text"), source_wins: true)[:action]
    assert_equal "Source text", journal.reload.notes
  end

  def test_deleted_note_is_a_conflict_or_created_again_when_the_source_wins
    journal = Journal.find(sync_note(note("Source text"))[:destination_id])
    journal.destroy
    assert_raises(RedmineMirror::Error) { sync_note(note("Source text")) }
    event = sync_note(note("Source text"), source_wins: true)
    assert_equal "create", event[:action]
    assert_equal "Source text", Journal.find(event[:destination_id]).notes
  end

  def test_members_roles_follow_the_source_exactly_when_it_wins
    record = { "id" => 1, "project" => { "id" => 9 }, "user" => { "id" => 7 }, "roles" => [{ "id" => 42, "name" => "Developer" }] }
    mappings = { "user" => { "7" => "2" }, "role" => { "42" => "2" } }
    adapter = RedmineMirror::Adapters::Members.new
    sync = ->(wins) { mirror(source_wins: wins) { adapter.synchronize(record, project_id: 1, mappings: mappings, lookup: nil, store: @store, source: nil, apply: true) } }
    sync.call(false)
    assert_equal [1, 2], Project.find(1).memberships.find_by!(user_id: 2).role_ids.sort
    sync.call(true)
    assert_equal [2], Project.find(1).memberships.find_by!(user_id: 2).role_ids
  end

  def test_watchers_are_exactly_the_source_ones_when_it_wins
    @issue.add_watcher(User.find(3))
    record = { "id" => 900, "project" => { "id" => 9 }, "watchers" => [{ "id" => 7 }] }
    mirror(source_wins: true) do
      RedmineMirror::Adapters::Watchers.new.synchronize(record, project_id: 1, mappings: @mappings, lookup: @lookup, store: @store, source: nil, apply: true)
    end
    assert_equal [2], @issue.reload.watcher_users.pluck(:id)
  end

  def test_a_version_still_used_locally_is_not_deleted
    assert_raises(RedmineMirror::Error) { RedmineMirror::Adapters::Versions.new.delete_local(2, 1) }
    assert Version.exists?(2)
    RedmineMirror::Adapters::Versions.new.delete_local(3, 1)
    refute Version.exists?(3)
  end
end
