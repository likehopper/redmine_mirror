# frozen_string_literal: true
# File: redmine_mirror/test/unit/locked_references_test.rb
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
# Locked users and closed versions: held back from REST writes, restored locally.

require_relative "../test_helper"

class MirrorLockedReferencesTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :issues, :issue_statuses,
    :trackers, :projects_trackers, :enumerations, :enabled_modules, :versions, :time_entries, :watchers

  LOCKED = 5 # dlopper2, locked member of project 1

  def setup
    @project = Project.find(1)
    assert User.find(LOCKED).locked?
  end

  def test_user_choices_include_locked_members_only
    ids = RedmineMirror::MappingTable.new("user").local_records(@project).map(&:id)
    assert_includes ids, LOCKED
    assert_includes ids, 2
    refute_includes ids, 8 # active, not a member
  end

  def test_issue_holds_back_locked_assignee_and_closed_versions
    adapter = RedmineMirror::Adapters::Issues.new
    payload = { "subject" => "S", "assigned_to_id" => LOCKED, "fixed_version_id" => 1, "project_id" => 1 }
    assert_equal({ "subject" => "S", "project_id" => 1 }, adapter.rest_attributes(payload))
    assert_equal ["fixed_version_id"], adapter.local_references(payload.merge("assigned_to_id" => 2, "fixed_version_id" => 2))
    open = payload.merge("assigned_to_id" => 2, "fixed_version_id" => 3)
    assert_same open, adapter.rest_attributes(open)
  end

  def test_issue_rejects_a_version_not_shared_with_the_project
    error = assert_raises(RedmineMirror::Error) do
      RedmineMirror::Adapters::Issues.new.rest_attributes("fixed_version_id" => 5, "project_id" => 1)
    end
    assert_match(/not shared/, error.message)
  end

  def test_issue_restores_held_back_references_locally
    issue = Issue.find(1)
    journals = issue.journals.count
    RedmineMirror::Adapters::Issues.new.restore_metadata({ "assigned_to_id" => LOCKED, "fixed_version_id" => 1, "project_id" => 1 }, issue.id, 1)
    issue.reload
    assert_equal [LOCKED, 1], [issue.assigned_to_id, issue.fixed_version_id]
    assert_equal journals, issue.journals.count
  end

  def test_time_entry_of_a_locked_user_is_given_back_locally
    adapter = RedmineMirror::Adapters::TimeEntries.new
    entry = TimeEntry.where(project_id: 1).first
    payload = { "hours" => 1.0, "user_id" => LOCKED, "project_id" => 1 }
    assert_equal({ "hours" => 1.0, "project_id" => 1 }, adapter.rest_attributes(payload))
    adapter.restore_metadata(payload, entry.id, 1)
    assert_equal LOCKED, entry.reload.user_id
    active = payload.merge("user_id" => 2)
    assert_same active, adapter.rest_attributes(active)
  end

  def test_locked_watchers_are_not_subscribed
    issue = Issue.find(1)
    record = { "id" => 100, "watchers" => [{ "id" => 7 }, { "id" => 8 }] }
    mapped = RedmineMirror::Adapters::Watchers.new.mapped_watchers(record, { "user" => { "7" => LOCKED.to_s, "8" => "2" } }, issue)
    assert_equal [2], mapped
  end
end
