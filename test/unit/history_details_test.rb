# frozen_string_literal: true
# File: redmine_mirror/test/unit/history_details_test.rb
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
# Verify that history details Mirror cannot translate are skipped, not fatal.
require_relative "../test_helper"

class MirrorHistoryDetailsTest < ActiveSupport::TestCase
  def test_history_skips_details_it_cannot_translate_but_keeps_the_journal
    journals = RedmineMirror::Adapters::Journals.new
    record = { "id" => 5, "user" => { "id" => 1 }, "created_on" => "2026-01-02T03:04:05Z", "notes" => "Kept note", "details" => [
      { "property" => "attachment", "name" => "12", "old_value" => nil, "new_value" => "a.png" },
      { "property" => "attr", "name" => "project_id", "old_value" => "3", "new_value" => "4" },
      { "property" => "attr", "name" => "category_id", "old_value" => nil, "new_value" => "9" },
      { "property" => "attr", "name" => "subject", "old_value" => "Old", "new_value" => "New" }] }
    RedmineMirror::TextFormat.reset_flags
    attributes = journals.imported_attributes(record, { "user" => { "1" => "1" } }, lookup: ->(*) {})
    assert_equal [["attr", "subject", "Old", "New"]], attributes.fetch("details")
    assert_equal "Kept note", attributes.fetch("notes")
    assert_includes RedmineMirror::TextFormat.flags, "history_details_skipped"
    assert_nil journals.skip_reason(attributes)
    assert journals.skip_reason(attributes.merge("notes" => "", "details" => []))
  end
end
