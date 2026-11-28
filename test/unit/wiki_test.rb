# frozen_string_literal: true
# File: redmine_mirror/test/unit/wiki_test.rb
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

class MirrorWikiTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :wikis, :wiki_pages, :wiki_contents, :wiki_content_versions

  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
  end

  # Source wiki: a home page (version 2 deleted) and its child, listed child first.
  class Source
    PAGES = {
      "Mirror_home" => { "title" => "Mirror_home", "version" => 3, "text" => "h1. Home\n\nFinal", "comments" => "Final",
        "author" => { "id" => 7, "name" => "Remote" }, "created_on" => "2026-01-10T09:00:00Z", "updated_on" => "2026-01-12T09:00:00Z" },
      "Mirror_child" => { "title" => "Mirror_child", "parent" => { "title" => "Mirror_home" }, "version" => 1, "text" => "Child",
        "comments" => "", "author" => { "id" => 7, "name" => "Remote" }, "created_on" => "2026-01-11T09:00:00Z", "updated_on" => "2026-01-11T09:00:00Z" }
    }.freeze
    OLD = { "text" => "First", "version" => 1, "comments" => "Created", "author" => { "id" => 8, "name" => "Other" }, "updated_on" => "2026-01-10T09:00:00Z" }.freeze

    # Redmine 4.0 answers a deleted version with the current one, Redmine 5 with 404.
    # The start page is Mirror_home; without one, the wiki's URL answers 404.
    attr_reader :paths

    def initialize(deleted_as_current: false, start_page: true)
      @deleted_as_current = deleted_as_current
      @start_page = start_page
      @paths = []
    end

    def get(path, _params = {})
      @paths << path
      case path
      when "projects/9/wiki.json"
        raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}" unless @start_page
        { "wiki_page" => PAGES.fetch("Mirror_home") }
      when "projects/9/wiki/index.json" then { "wiki_pages" => PAGES.values.reverse.map { |page| page.slice("title", "parent", "version", "updated_on") } }
      when "projects/9/wiki/Mirror_home/1.json" then { "wiki_page" => PAGES.fetch("Mirror_home").merge(OLD) }
      when "projects/9/wiki/Mirror_home/2.json"
        raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}" unless @deleted_as_current
        { "wiki_page" => PAGES.fetch("Mirror_home") }
      when %r{\Aprojects/9/wiki/(\w+)\.json\z} then { "wiki_page" => PAGES.fetch(Regexp.last_match(1)) }
      else raise "Unexpected #{path}"
      end
    end
  end

  # The same wiki after Mirror_child was moved to the top level on the source.
  class MovedSource < Source
    def get(path, params = {})
      top_level = ->(page) { page["title"] == "Mirror_child" ? page.except("parent") : page }
      result = super
      result.merge("wiki_pages" => result["wiki_pages"]&.map(&top_level), "wiki_page" => result["wiki_page"] && top_level.call(result["wiki_page"])).compact
    end
  end

  class AttachmentSource < Source
    attr_accessor :available

    def initialize
      super
      @available = false
    end

    def get(path, params = {})
      result = super
      return result unless path == "projects/9/wiki/Mirror_home.json"
      result.merge("wiki_page" => result.fetch("wiki_page").merge("attachments" => [{ "id" => 501,
        "filename" => "wiki-note.txt", "filesize" => 5, "content_type" => "text/plain", "description" => "",
        "created_on" => "2026-01-12T09:00:00Z", "author" => { "id" => 7, "name" => "Remote" } }]))
    end

    def download_attachment(id, max_bytes:, path: nil)
      raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET attachments/download/#{id}" unless available
      "file\n"
    end
  end

  def setup
    @project = Project.find(1)
    @store = Store.new
    @adapter = RedmineMirror::Adapters::Wiki.new
    @mappings = { "user" => { "7" => "2", "8" => "3" } }
    @lookup = ->(key, id) { @store.find(key, id)&.fetch("destination_id") }
  end

  def sync(apply: true, source: Source.new)
    @adapter.records(source, 9).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store, source: source, apply: apply)
    end
  end

  def listed_sync(source, changed: [], recover_missing_files: false)
    @adapter.listed_records(source, 9, store: @store, changed: changed).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store,
        source: source, apply: true, recover_missing_files: recover_missing_files)
    end
  end

  def test_unchanged_pages_are_listed_from_the_index_without_their_detail
    sync
    source = Source.new
    assert_equal %w[unchanged unchanged], listed_sync(source).map { |event| event[:action] }
    assert_equal %w[projects/9/wiki/index.json projects/9/wiki.json], source.paths
  end

  # Journaled files, a local edit or a page moved under another parent need the detail.
  def test_changed_moved_or_locally_edited_pages_read_their_detail
    sync
    home = @project.wiki.find_page("Mirror_home")
    child = @project.wiki.find_page("Mirror_child")
    source = Source.new
    listed_sync(source, changed: [RedmineMirror::Adapters::Wiki.source_id("Mirror_child")])
    assert_includes source.paths, "projects/9/wiki/Mirror_child.json"
    assert_not_includes source.paths, "projects/9/wiki/Mirror_home.json"

    source = MovedSource.new
    events = listed_sync(source).to_h { |event| [event[:source_id], event[:action]] }
    assert_equal "update", events.fetch(RedmineMirror::Adapters::Wiki.source_id("Mirror_child"))
    assert_equal "unchanged", events.fetch(RedmineMirror::Adapters::Wiki.source_id("Mirror_home"))
    assert_includes source.paths, "projects/9/wiki/Mirror_child.json"
    assert_nil child.reload.parent_id

    home.content.text = "Local edit"
    home.content.save!
    source = MovedSource.new
    error = assert_raises(RedmineMirror::Error) { listed_sync(source) }
    assert_match(/Local modification detected for wiki page "Mirror_home"/, error.message)
    assert_includes source.paths, "projects/9/wiki/Mirror_home.json"
  end

  def test_deleted_version_answered_as_the_current_one_stays_a_gap
    sync(source: Source.new(deleted_as_current: true))
    assert_equal [1, 3], @project.wiki.find_page("Mirror_home").content.versions.order(:version).pluck(:version)
  end

  def test_pages_versions_parents_and_dates_without_notifications
    with_settings notified_events: %w[wiki_content_added wiki_content_updated] do
      ActionMailer::Base.deliveries.clear
      assert_equal %w[create create], sync(apply: false).map { |event| event[:action] }
      assert_nil @project.wiki.find_page("Mirror_home")
      sync
      home = @project.wiki.find_page("Mirror_home")
      child = @project.wiki.find_page("Mirror_child")
      assert_equal home.id, child.parent_id
      assert_equal [1, 3], home.content.versions.order(:version).pluck(:version)
      assert_equal [3, 2], home.content.versions.order(:version).pluck(:author_id)
      assert_equal "First", home.content.versions.find_by(version: 1).text
      assert_equal Time.utc(2026, 1, 12, 9), home.content.updated_on
      assert_equal Time.utc(2026, 1, 10, 9), home.created_on
      assert_empty ActionMailer::Base.deliveries
    end
    assert_equal %w[unchanged unchanged], sync.map { |event| event[:action] }
  end

  def test_local_edit_and_unmatched_local_page_are_conflicts
    sync
    child = @project.wiki.find_page("Mirror_child")
    child.content.text = "Local edit"
    child.content.save!
    error = assert_raises(RedmineMirror::Error) { sync }
    assert_match(/Local modification detected for wiki page "Mirror_child"/, error.message)
    assert_raises(RedmineMirror::Error) do
      @store = Store.new
      sync(apply: false)
    end
  end

  def test_local_edit_is_replaced_by_the_source_versions_when_it_wins
    sync
    child = @project.wiki.find_page("Mirror_child")
    home = @project.wiki.find_page("Mirror_home")
    home.content.text = "Local edit"
    home.content.save!
    RedmineMirror::Policy.with(source_wins: true) { sync }
    home.reload
    assert_equal [1, 3], home.content.versions.order(:version).pluck(:version)
    assert_equal "h1. Home\n\nFinal", home.content.text
    assert_equal home.id, child.reload.parent_id
    assert_equal %w[unchanged unchanged], sync.map { |event| event[:action] }
  end

  # A new project's wiki starts on "Wiki", a page that does not exist: the source start
  # page replaces it. A start page that exists locally is kept, unless the source wins.
  def test_source_start_page_replaces_a_missing_local_one
    wiki = @project.wiki
    wiki.update!(start_page: "Wiki")
    assert_equal %w[create create], sync(apply: false).map { |event| event[:action] }
    assert_equal "Wiki", wiki.reload.start_page
    sync
    assert_equal "Mirror_home", wiki.reload.start_page
    assert_equal %w[unchanged unchanged], sync.map { |event| event[:action] }
  end

  def test_existing_local_start_page_is_kept_unless_the_source_wins
    wiki = @project.wiki
    local = wiki.start_page
    assert wiki.find_page(local)
    sync
    assert_equal local, wiki.reload.start_page
    assert_equal %w[update unchanged], RedmineMirror::Policy.with(source_wins: true) { sync(apply: false) }.map { |event| event[:action] }
    RedmineMirror::Policy.with(source_wins: true) { sync }
    assert_equal "Mirror_home", wiki.reload.start_page
  end

  def test_source_without_start_page_leaves_the_local_one
    wiki = @project.wiki
    wiki.update!(start_page: "Wiki")
    sync(source: Source.new(start_page: false))
    assert_equal "Wiki", wiki.reload.start_page
  end

  def test_missing_version_author_mapping_fails_in_preview
    @mappings = { "user" => { "7" => "2" } }
    assert_raises(RedmineMirror::Error) { sync(apply: false) }
  end

  def test_missing_wiki_file_is_retried_and_replaced_when_source_returns
    setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example", source_project_id: 9)
    setting.api_key = "unit-test-key"
    setting.module_options = { "wiki" => { "missing_file" => "placeholder" } }
    setting.save!
    source = AttachmentSource.new
    with_settings attachment_max_size: 1024 do
      sync(source: source)
      page = @project.wiki.find_page("Mirror_home")
      first = page.attachments.find_by!(filename: "wiki-note.txt")
      assert_includes File.read(first.diskfile), "not available on the source"
      assert_equal RedmineMirror::Adapters::Attachments::MISSING_FINGERPRINT,
        @store.find("wiki_attachments", 501)["source_fingerprint"]
      database_store = RedmineMirror::DatabaseStore.new("wiki-recovery-test", project_id: @project.id)
      page_id = @adapter.class.source_id("Mirror_home")
      database_store.save("wiki", page_id, @store.find("wiki", page_id))
      database_store.save("wiki_attachments", 501, @store.find("wiki_attachments", 501))
      assert_empty database_store.retries
      assert_equal [{ "module_key" => "wiki", "source_id" => page_id, "action" => "upsert" }],
        database_store.retries(recover_missing_files: true)
      downloads = source.paths.size
      assert_equal %w[unchanged unchanged], listed_sync(source).map { |event| event[:action] }
      assert_equal downloads + 2, source.paths.size
      assert_equal %w[update unchanged], listed_sync(source,
        changed: [@adapter.class.source_id("Mirror_home")], recover_missing_files: true).map { |event| event[:action] }
      assert_equal first.id, page.attachments.find_by!(filename: "wiki-note.txt").id
      original_description = first.description
      first.update!(description: "Local edit")
      assert_match(/Local modification detected for wiki_attachments/, assert_raises(RedmineMirror::Error) do
        listed_sync(source, changed: [@adapter.class.source_id("Mirror_home")], recover_missing_files: true)
      end.message)
      first.update!(description: original_description)
      source.available = true
      assert_equal %w[unchanged unchanged], listed_sync(source).map { |event| event[:action] }
      assert_equal %w[update unchanged], listed_sync(source,
        changed: [@adapter.class.source_id("Mirror_home")], recover_missing_files: true).map { |event| event[:action] }
      restored = page.attachments.find_by!(filename: "wiki-note.txt")
      assert_not_equal first.id, restored.id
      assert_equal "file\n", File.binread(restored.diskfile)
      assert_not_equal RedmineMirror::Adapters::Attachments::MISSING_FINGERPRINT,
        @store.find("wiki_attachments", 501)["source_fingerprint"]
      fresh_source = AttachmentSource.new
      fresh_source.available = true
      assert_equal %w[unchanged unchanged], listed_sync(fresh_source).map { |event| event[:action] }
      assert_not_includes fresh_source.paths, "projects/9/wiki/Mirror_home.json"
    end
  end
end
