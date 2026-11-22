# frozen_string_literal: true
# File: redmine_mirror/test/diagnosis_test.rb
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
# Verify that run errors are recognized by cause, also in logs written before details.

require "minitest/autorun"
require_relative "../lib/redmine_mirror"

class MirrorDiagnosisTest < Minitest::Test
  def cause(reason, details = nil)
    RedmineMirror::Diagnosis.cause(reason, details)
  end

  def test_known_texts_give_a_cause_and_its_parameters
    assert_equal ["missing_mapping", { "kind" => "status", "id" => "12" }], cause("Missing status mapping for source ID 12")
    assert_equal ["missing_reference", { "field" => "fixed_version", "id" => "44", "name" => "2.0" }],
      cause('Missing fixed_version correspondence for source issue #9 (fixed_version #44 "2.0"); select its module')
    assert_equal ["field_not_on_tracker", { "name" => "Impact" }], cause('Custom field "Impact" is not enabled for destination tracker "Bug": enable it')
    assert_equal "conflict", cause("Local modification detected for issue_tracking source ID 3").first
    assert_equal ["project_module", { "module" => "wiki" }], cause("Enable the Wiki module on the destination project")
    assert_equal ["source_permission", { "path" => "projects/12/wiki/index.json" }], cause("Redmine API returned HTTP 403 for GET projects/12/wiki/index.json")
    assert_nil cause("Destination rejected issue: Subject cannot be blank")
  end

  # Consequences of another failure are one group per kind, apart from the causes.
  def test_shared_causes_and_consequences_are_grouped
    events = [
      { "module" => "issue_journals", "action" => "error", "reason" => "Missing destination issue correspondence" },
      { "module" => "time_tracking", "action" => "error", "reason" => "Issue has no synchronized destination" },
      { "module" => "issue_attachments", "action" => "error", "reason" => "Redmine API returned HTTP 404 for GET attachments/download/328" },
      { "module" => "issue_attachments", "action" => "error", "reason" => "Redmine API returned HTTP 404 for GET attachments/download/500" },
      { "module" => "issue_tracking", "action" => "error", "reason" => "Redmine API returned HTTP 422 for POST issues.json: Assignee is invalid",
        "details" => { "code" => "assignee_not_assignable", "id" => "7", "name" => "Ann" } }]
    groups = RedmineMirror::Diagnosis.groups(events).to_h { |group| [group[:key], group] }
    assert_equal({ "issue_journals" => 1, "time_tracking" => 1 }, groups.fetch("issue_not_imported")[:modules])
    assert groups.fetch("issue_not_imported")[:consequence]
    assert_equal 2, groups.fetch("source_file_missing")[:count]
    refute groups.fetch("assignee_not_assignable:7")[:consequence]
  end

  def test_details_win_over_the_text
    details = { "code" => "missing_reference", "field" => "fixed_version", "id" => "44", "owner_id" => "30" }
    assert_equal ["missing_reference", details], cause("anything", details)
  end

  def test_groups_count_objects_per_cause_largest_first
    events = [3, 4, 5].map { |id| { "action" => "error", "source_id" => id, "reason" => "Missing user mapping for source ID 7" } } +
      [{ "action" => "error", "source_id" => 8, "reason" => "Missing status mapping for source ID 2" },
       { "action" => "create", "source_id" => 9 }]
    groups = RedmineMirror::Diagnosis.groups(events)
    assert_equal [["missing_mapping:user:7", 3], ["missing_mapping:status:2", 1]], groups.map { |group| [group[:key], group[:count]] }
  end
end
