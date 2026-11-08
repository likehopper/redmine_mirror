# frozen_string_literal: true
# File: redmine_mirror/test/unit/update_journals_test.rb
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
# With the history imported, an issue update is written like the REST API would, without a journal.

require_relative "../test_helper"

class MirrorUpdateJournalsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :issues, :issue_statuses,
    :trackers, :projects_trackers, :enumerations, :enabled_modules, :journals, :journal_details, :workflows, :versions

  def setup
    @adapter = RedmineMirror::Adapters::Issues.new
    @issue = Issue.find(1)
    User.current = User.anonymous
  end

  def test_the_update_is_written_without_journal_nor_notification
    journals = @issue.journals.count
    ActionMailer::Base.deliveries.clear
    with_settings notified_events: %w[issue_updated] do
      @adapter.update_locally(@issue.id, { "subject" => "Updated by Mirror", "priority_id" => 6, "author_id" => 3 }, User.find(1))
    end
    @issue.reload
    assert_equal ["Updated by Mirror", 6], [@issue.subject, @issue.priority_id]
    assert_equal 2, @issue.author_id, "attributes the REST API would not take are ignored too"
    assert_equal journals, @issue.journals.count
    assert_empty ActionMailer::Base.deliveries
    assert User.current.anonymous?, "the current user is restored"
  end

  def test_the_api_account_needs_the_right_to_edit_the_issue
    # User 7 is not a member of project 1: the Non member role decides.
    Role.non_member.remove_permission!(:edit_issues)
    error = assert_raises(RedmineMirror::Error) { @adapter.update_locally(@issue.id, { "subject" => "No" }, User.find(7)) }
    assert_match(/may not edit issue #1/, error.message)
    assert_not_equal "No", @issue.reload.subject
  end

  def test_issues_changed_with_it_are_journaled_as_for_a_rest_update
    duplicate = Issue.find(3)
    IssueRelation.create!(issue_from: duplicate, issue_to: @issue, relation_type: IssueRelation::TYPE_DUPLICATES)
    journals, duplicate_journals = @issue.journals.count, duplicate.journals.count
    with_settings close_duplicate_issues: "1" do
      @adapter.update_locally(@issue.id, { "status_id" => 5 }, User.find(1))
    end
    assert @issue.reload.closed?
    assert_equal journals, @issue.journals.count
    assert duplicate.reload.closed?
    assert_equal duplicate_journals + 1, duplicate.journals.count, "the closed duplicate keeps its journal"
  end

  def test_a_stale_issue_is_an_object_error
    error = assert_raises(RedmineMirror::Error) do
      @adapter.update_locally(@issue.id, { "subject" => "Stale", "lock_version" => @issue.lock_version + 5 }, User.find(1))
    end
    assert_match(/Destination rejected issue #1/, error.message)
  end

  def test_redmine_validations_still_refuse_the_update
    error = assert_raises(RedmineMirror::Error) { @adapter.update_locally(@issue.id, { "subject" => "" }, User.find(1)) }
    assert_match(/Destination rejected issue #1: Subject cannot be blank/, error.message)
  end
end
