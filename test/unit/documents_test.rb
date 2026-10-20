# frozen_string_literal: true
# File: redmine_mirror/test/unit/documents_test.rb
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
# Verify the Documents module: content, category, date, files, conflicts and mirror mode.

require_relative "../test_helper"

class MirrorDocumentsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :enumerations, :documents

  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
    def delete(key, id); @rows.delete([key, id]); end
    def mappings(key); @rows.filter_map { |(row_key, id), values| [id, values.fetch("destination_id")] if row_key == key }; end
  end

  FILE = "Release notes\n"

  class Source
    attr_accessor :documents
    attr_reader :downloads
    def initialize
      @documents = [{ "id" => 41, "project" => { "id" => 9, "name" => "Remote" }, "category" => { "id" => 71, "name" => "Specs" },
        "title" => "Specification", "description" => "h2. Scope", "created_on" => "2026-02-03T10:00:00Z",
        "attachments" => [{ "id" => 501, "filename" => "notes.txt", "filesize" => FILE.bytesize, "content_type" => "text/plain",
          "description" => "Notes", "author" => { "id" => 7, "name" => "Remote" }, "created_on" => "2026-02-03T10:05:00Z" }] }]
    end

    def get(path, _params = {})
      case path
      when "projects/9/mirror/source/documents.json" then { "documents" => @documents, "total_count" => @documents.size }
      when "enumerations/document_categories.json" then { "document_categories" => [{ "id" => 71, "name" => "Specs" }] }
      when "mirror/source/documents/41.json" then raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"
      else raise "Unexpected #{path}"
      end
    end

    # Document files come through the Mirror source path, not the attachments API.
    def download_attachment(_id, max_bytes:, path: nil)
      (@downloads ||= []) << path
      FILE.dup
    end
  end

  def setup
    @project = Project.find(1)
    @store = Store.new
    @source = Source.new
    @adapter = RedmineMirror::Adapters::Documents.new
    @mappings = { "user" => { "7" => "2" }, "document_category" => { "71" => "3" } }
    @lookup = ->(key, id) { @store.find(key, id)&.fetch("destination_id") }
  end

  def sync(apply: true)
    @adapter.records(@source, 9).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store, source: @source, apply: apply)
    end
  end

  def imported
    Document.find(@store.find("documents", 41).fetch("destination_id"))
  end

  def test_document_category_date_and_files_without_notifications
    with_settings notified_events: %w[document_added], attachment_max_size: 1024 do
      ActionMailer::Base.deliveries.clear
      assert_no_difference "Document.count" do
        assert_equal %w[create], sync(apply: false).map { |event| event[:action] }
      end
      sync
      document = imported
      assert_equal [@project.id, "Specification", 3], [document.project_id, document.title, document.category_id]
      assert_equal Time.utc(2026, 2, 3, 10), document.created_on
      attachment = document.attachments.sole
      assert_equal ["notes.txt", "Notes", 2, Time.utc(2026, 2, 3, 10, 5)], [attachment.filename, attachment.description, attachment.author_id, attachment.created_on]
      assert_equal FILE, File.read(attachment.diskfile)
      assert_equal ["mirror/source/attachments/501/download"], @source.downloads
      assert_empty ActionMailer::Base.deliveries
    end
    assert_equal %w[unchanged], sync.map { |event| event[:action] }
  end

  def test_source_changes_and_new_files_update_the_document
    with_settings attachment_max_size: 1024 do
      sync
      @source.documents.first["title"] = "Specification v2"
      @source.documents.first["attachments"] << @source.documents.first["attachments"].first.merge("id" => 502, "filename" => "annex.txt")
      assert_equal %w[update], sync.map { |event| event[:action] }
      assert_equal "Specification v2", imported.title
      assert_equal %w[annex.txt notes.txt], imported.attachments.map(&:filename).sort
    end
  end

  def test_local_edit_is_a_conflict_unless_the_source_wins
    with_settings attachment_max_size: 1024 do
      sync
      imported.update!(title: "Local title")
      error = assert_raises(RedmineMirror::Error) { sync }
      assert_match(/Local modification detected for document "Specification"/, error.message)
      RedmineMirror::Policy.with(source_wins: true) { sync }
      assert_equal "Specification", imported.title
    end
  end

  def test_mirror_mode_removes_files_gone_from_the_source
    with_settings attachment_max_size: 1024 do
      sync
      @source.documents.first["attachments"] = []
      RedmineMirror::Policy.with(source_wins: true) { sync }
      assert_empty imported.attachments
    end
  end

  def test_deletion_is_confirmed_by_the_source
    with_settings attachment_max_size: 1024 do
      sync
      document = imported
      assert_equal "deleted", @adapter.source_state(@source, 41, document.id, source_project_id: 9, project_id: @project.id)
      @adapter.delete_local(document.id, @project.id)
      assert_nil Document.find_by(id: document.id)
    end
  end

  def test_missing_mapping_disabled_module_and_source_without_mirror_fail
    @mappings = { "user" => { "7" => "2" } }
    assert_raises(RedmineMirror::Error) { sync(apply: false) }
    @mappings = { "user" => {}, "document_category" => { "71" => "3" } }
    assert_raises(RedmineMirror::Error) { sync(apply: false) }
    @project.disable_module!(:documents)
    @mappings = { "user" => { "7" => "2" }, "document_category" => { "71" => "3" } }
    assert_match(/Enable the Documents module/, assert_raises(RedmineMirror::Error) { sync(apply: false) }.message)
    source = Object.new
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"; end
    assert_match(/install Redmine Mirror/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
    # A refusal names the lock to open on the source.
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path} (Mirror source: not_shared)"; end
    assert_match(/Share Documents/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path}"; end
    assert_match(/needs View documents/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
  end

  def test_catalog_lists_categories_and_file_authors
    catalog = RedmineMirror::SourceCatalog.new(client: Class.new(Source) { def get(path, params = {}); path == "projects/9.json" ? {} : super; end }.new,
      project_id: 9, adapters: [@adapter]).fetch
    assert_equal({ "71" => "Specs" }, catalog.fetch("document_category"))
    assert_equal ["71"], catalog.fetch("document_category_used")
  end
end
