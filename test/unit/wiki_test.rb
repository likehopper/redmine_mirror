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

    def get(path, _params = {})
      case path
      when "projects/9/wiki/index.json" then { "wiki_pages" => PAGES.values.reverse.map { |page| page.slice("title", "parent", "version") } }
      when "projects/9/wiki/Mirror_home/1.json" then { "wiki_page" => PAGES.fetch("Mirror_home").merge(OLD) }
      when "projects/9/wiki/Mirror_home/2.json" then raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"
      when %r{\Aprojects/9/wiki/(\w+)\.json\z} then { "wiki_page" => PAGES.fetch(Regexp.last_match(1)) }
      else raise "Unexpected #{path}"
      end
    end
  end

  def setup
    @project = Project.find(1)
    @store = Store.new
    @adapter = RedmineMirror::Adapters::Wiki.new
    @mappings = { "user" => { "7" => "2", "8" => "3" } }
    @lookup = ->(key, id) { @store.find(key, id)&.fetch("destination_id") }
  end

  def sync(apply: true)
    @adapter.records(Source.new, 9).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store, source: Source.new, apply: apply)
    end
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

  def test_missing_version_author_mapping_fails_in_preview
    @mappings = { "user" => { "7" => "2" } }
    assert_raises(RedmineMirror::Error) { sync(apply: false) }
  end
end
