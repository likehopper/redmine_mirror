# frozen_string_literal: true
# File: redmine_mirror/test/unit/attachments_test.rb
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
# Verify that attachment contents cross the source boundary only when needed.

require_relative "../test_helper"

class MirrorAttachmentsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :issues, :trackers, :issue_statuses, :enumerations

  class Store
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
  end

  class Source
    attr_reader :downloads

    def initialize
      @downloads = []
    end

    def download_attachment(id, max_bytes:, path: nil)
      @downloads << [id, max_bytes, path]
      "file\n"
    end
  end

  def setup
    @adapter = RedmineMirror::Adapters::Attachments.new
    @issue = Issue.find(1)
    @store = Store.new
    @source = Source.new
    @record = {
      "id" => 501, "issue_id" => 1, "filename" => "proof.txt", "filesize" => 5,
      "content_type" => "text/plain", "description" => "", "created_on" => "2026-11-22T10:00:00Z",
      "author" => { "id" => 7, "name" => "Remote" }
    }
  end

  def synchronize(mappings: { "user" => { "7" => "2" } }, issue_id: @issue.id, recover_missing_files: false)
    @adapter.synchronize(@record, project_id: @issue.project_id, mappings: mappings,
      lookup: ->(key, _id) { issue_id if key == "issue_tracking" }, store: @store, source: @source, apply: true,
      recover_missing_files: recover_missing_files)
  end

  class MissingSource < Source
    def download_attachment(id, max_bytes:, path: nil)
      @downloads << [id, max_bytes, path]
      raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET attachments/download/#{id}"
    end
  end

  def missing_file(choice)
    setting = MirrorProjectSetting.new(project: @issue.project, source_url: "https://source.example", source_project_id: 99)
    setting.api_key = "unit-test-key"
    setting.module_options = { "issue_attachments" => { "missing_file" => choice } }
    setting.save!
    @source = MissingSource.new
  end

  def test_a_file_missing_on_the_source_follows_the_module_option
    with_settings attachment_max_size: 1024, default_language: "en" do
      missing_file("retry")
      assert_raises(RedmineMirror::Error) { synchronize }
      @issue.project.mirror_project_setting.update!(module_options: { "issue_attachments" => { "missing_file" => "skip" } })
      event = synchronize
      assert_equal ["ignored", nil], [event[:action], event[:destination_id]]
      assert_match(/Source file missing/, event[:reason])
      assert_equal 0, @issue.reload.attachments.where(filename: "proof.txt").count
      @issue.project.mirror_project_setting.update!(module_options: { "issue_attachments" => { "missing_file" => "placeholder" } })
      event = synchronize
      attachment = @issue.reload.attachments.find(event[:destination_id])
      assert_equal ["create", "proof.txt", "text/plain"], [event[:action], attachment.filename, attachment.content_type]
      assert_includes File.read(attachment.diskfile), "not available on the source"
      assert_equal "File not available on the source", attachment.description
      assert_equal RedmineMirror::Adapters::Attachments::MISSING_FINGERPRINT, @store.find("issue_attachments", 501)["source_fingerprint"]
      downloads = @source.downloads.size
      assert_equal "unchanged", synchronize[:action]
      assert_equal downloads, @source.downloads.size
      assert_equal "update", synchronize(recover_missing_files: true)[:action]
      assert_equal attachment.id, @issue.reload.attachments.find_by!(filename: "proof.txt").id
      @source = Source.new
      assert_equal "unchanged", synchronize[:action]
      restored = synchronize(recover_missing_files: true)
      assert_equal "update", restored[:action]
      assert_equal "file\n", File.binread(@issue.reload.attachments.find(restored[:destination_id]).diskfile)
      assert_not_equal attachment.id, restored[:destination_id]
      assert_not_equal RedmineMirror::Adapters::Attachments::MISSING_FINGERPRINT, @store.find("issue_attachments", 501)["source_fingerprint"]
      assert_equal "unchanged", synchronize[:action]
    end
  end

  def test_pdf_and_image_placeholders_have_valid_file_types
    with_settings attachment_max_size: 1024, default_language: "en" do
      missing_file("placeholder")
      { "report.pdf" => ["application/pdf", "%PDF"], "photo.jpg" => ["image/jpeg", "\xFF\xD8".b],
        "chart.png" => ["image/png", "\x89PNG".b] }.each_with_index do |(filename, (mime, header)), index|
        @record = @record.merge("id" => 501 + index, "filename" => filename, "content_type" => mime)
        event = synchronize
        attachment = @issue.reload.attachments.find(event.fetch(:destination_id))
        assert_equal filename, attachment.filename
        assert_equal mime, attachment.content_type
        assert File.binread(attachment.diskfile).start_with?(header)
      end
    end
  end

  def test_provisional_attachment_is_included_in_incremental_retries
    with_settings attachment_max_size: 1024 do
      missing_file("placeholder")
      attachment_id = synchronize.fetch(:destination_id)
      store = RedmineMirror::DatabaseStore.new("placeholder-test", project_id: @issue.project_id)
      store.save("issue_tracking", 1001, "destination_id" => @issue.id,
        "source_fingerprint" => "a" * 64, "destination_fingerprint" => "b" * 64)
      store.save("issue_attachments", 501, @store.find("issue_attachments", 501).merge("destination_id" => attachment_id))
      assert_empty store.retries
      assert_equal [{ "module_key" => "issue_attachments", "source_id" => 501, "action" => "upsert", "parent_id" => 1001 }],
        store.retries(recover_missing_files: true)
      assert_empty RedmineMirror::DatabaseStore.new("another-connection", project_id: @issue.project_id).retries
    end
  end

  def test_related_objects_are_the_issue_and_the_author
    assert_equal [["issue_tracking", 1], ["user", 7]], @adapter.related_references(@record)
  end

  def test_missing_issue_or_author_never_downloads_the_file
    with_settings attachment_max_size: 1024 do
      issue_error = assert_raises(RedmineMirror::Error) { synchronize(issue_id: nil) }
      assert_equal "Missing destination issue correspondence", issue_error.message
      author_error = assert_raises(RedmineMirror::Error) { synchronize(mappings: { "user" => { "7" => "999999" } }) }
      assert_equal "Missing destination attachment author", author_error.message
    end

    assert_empty @source.downloads
  end

  def test_unchanged_attachment_is_not_downloaded_again
    with_settings attachment_max_size: 1024 do
      assert_equal "create", synchronize.fetch(:action)
      assert_equal 1, @source.downloads.size
      assert_equal "unchanged", synchronize.fetch(:action)
      assert_equal 1, @source.downloads.size
    end
  end
end
