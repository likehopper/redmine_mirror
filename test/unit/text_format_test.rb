# frozen_string_literal: true
# File: redmine_mirror/test/unit/text_format_test.rb
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
# Verify text format conversion with the destination Redmine's own formatters.
require_relative "../test_helper"

class MirrorTextFormatTest < ActiveSupport::TestCase
  def convert(text, source: "auto", target: "CKEditor", fallback: nil)
    RedmineMirror::TextFormat.transform(text, source: source, target: target, fallback: fallback)
  end

  def test_textile_becomes_html_and_keeps_redmine_syntax
    html = convert("h2. Notes\n\n*Bold* and @code@, see #12, [[Wiki page]] and {{toc}}.\n\n!shot.png!")
    assert_includes html, "<h2>Notes</h2>"
    assert_includes html, "<strong>Bold</strong>"
    assert_includes html, "<code>code</code>"
    # Redmine links and macros are interpreted when the destination renders the HTML.
    %w[#12 [[Wiki\ page]] {{toc}}].each { |syntax| assert_includes html, syntax }
    assert_match(/<img src="shot.png"/, html)
  end

  def test_markdown_becomes_html
    html = convert("## Notes\n\n**Bold** and `code`.", source: "markdown")
    assert_includes html, "<strong>Bold</strong>"
    assert_includes html, "<code>code</code>"
  end

  def test_html_becomes_textile_or_markdown
    assert_includes convert("<p><strong>Bold</strong> text</p>", target: "textile"), "*Bold* text"
    assert_includes convert("<p><strong>Bold</strong> text</p>", target: "common_mark"), "**Bold** text"
  end

  def test_same_format_and_html_sources_are_unchanged
    assert_equal "h2. Title", convert("h2. Title", target: "textile")
    assert_equal "<p>Kept</p>", convert("<p>Kept</p>")
    assert_equal "## Title", convert("## Title", source: "markdown", target: "common_mark")
  end

  # Unmarked text is read in the project's dominant format: *x* is bold in Textile,
  # italic in Markdown.
  def test_auto_uses_the_dominant_format_for_ambiguous_texts
    assert_includes convert("An *emphasis*"), "<strong>emphasis</strong>"
    assert_includes convert("An *emphasis*", fallback: "markdown"), "<em>emphasis</em>"
    assert_equal "markdown", RedmineMirror::TextFormat.dominant("markdown" => 5, "textile" => 2, "plain" => 9)
    assert_nil RedmineMirror::TextFormat.dominant("plain" => 3)
    assert_equal "textile", RedmineMirror::TextFormat.dominant("html" => 9, "textile" => 1)
  end

  def test_conversion_applies_only_inside_a_synchronization_context
    assert_equal "*Bold*", RedmineMirror::TextFormat.convert("*Bold*")
    RedmineMirror::TextFormat.with("source" => "textile", "target" => "CKEditor") do
      assert_includes RedmineMirror::TextFormat.convert("*Bold*"), "<strong>Bold</strong>"
      payload = RedmineMirror::Adapters::Issues.new.payload(
        { "subject" => "S", "description" => "*Bold*", "tracker" => { "id" => 1 }, "status" => { "id" => 1 }, "priority" => { "id" => 4 } },
        1, { "tracker" => { "1" => 1 }, "status" => { "1" => 1 }, "priority" => { "4" => 4 } }, ->(*) {})
      assert_includes payload.fetch("description"), "<strong>Bold</strong>"
    end
    assert_equal "*Bold*", RedmineMirror::TextFormat.convert("*Bold*")
  end

  def test_conversion_notes_special_cases_for_the_execution_log
    RedmineMirror::TextFormat.with("source" => "auto", "target" => "CKEditor", "source_url" => "https://old.example") do
      RedmineMirror::TextFormat.reset_flags
      RedmineMirror::TextFormat.convert("*Bold*, see #4 and <img src=\"/system/rich/rich_files/1/a.png\">")
      assert_equal ["issue_references", "images", "rich_images", "converted:textile>html"], RedmineMirror::TextFormat.flags
      RedmineMirror::TextFormat.reset_flags
      RedmineMirror::TextFormat.convert("<p>Kept</p>")
      assert_empty RedmineMirror::TextFormat.flags
    end
  end

  def test_destination_format_follows_the_setting
    with_settings text_formatting: "common_mark" do
      assert_equal "common_mark", RedmineMirror::TextFormat.destination_format(Project.find(1))
    end
  end
end
