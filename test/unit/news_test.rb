# frozen_string_literal: true
# File: redmine_mirror/test/unit/news_test.rb
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

class MirrorNewsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :news, :comments

  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    # Like DatabaseStore: every correspondence carries both fingerprints.
    def save(key, id, values)
      raise ActiveRecord::RecordInvalid, MirrorMapping.new if %w[destination_id source_fingerprint destination_fingerprint].any? { |field| values[field].blank? }
      @rows[[key, id]] = values
    end
    def delete(key, id); @rows.delete([key, id]); end
    def mappings(key); @rows.filter_map { |(row_key, id), values| [id, values.fetch("destination_id")] if row_key == key }; end
  end

  FILE = "Release plan\n"

  class Source
    attr_accessor :news
    attr_reader :downloads
    def initialize
      @news = [{ "id" => 61, "project" => { "id" => 9, "name" => "Remote" }, "author" => { "id" => 7, "name" => "Remote" },
        "title" => "Release 2.0", "summary" => "What changes", "description" => "h2. Highlights", "created_on" => "2026-03-01T09:00:00Z",
        "comments" => [{ "id" => 801, "author" => { "id" => 8, "name" => "Other" }, "content" => "Great *news*",
          "created_on" => "2026-03-02T10:00:00Z", "updated_on" => "2026-03-02T10:00:00Z" }],
        "attachments" => [{ "id" => 901, "filename" => "plan.txt", "filesize" => FILE.bytesize, "content_type" => "text/plain",
          "description" => "Plan", "author" => { "id" => 7, "name" => "Remote" }, "created_on" => "2026-03-01T09:05:00Z" }] }]
    end

    def get(path, _params = {})
      case path
      when "projects/9/mirror/source/news.json" then { "news" => @news, "total_count" => @news.size }
      when "mirror/source/news/61.json" then raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"
      when "projects/9/mirror/source/users.json" then raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"
      else raise "Unexpected #{path}"
      end
    end

    # News files come through the Mirror source path, not the attachments API.
    def download_attachment(_id, max_bytes:, path: nil)
      (@downloads ||= []) << path
      FILE.dup
    end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:news)
    @store = Store.new
    @source = Source.new
    @adapter = RedmineMirror::Adapters::News.new
    @mappings = { "user" => { "7" => "2", "8" => "3" } }
    @lookup = ->(key, id) { @store.find(key, id)&.fetch("destination_id") }
  end

  def sync(apply: true)
    @adapter.records(@source, 9).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store, source: @source, apply: apply)
    end
  end

  def imported
    News.find(@store.find("news", 61).fetch("destination_id"))
  end

  def test_news_author_date_comments_and_files_without_notifications
    with_settings notified_events: %w[news_added news_comment_added], attachment_max_size: 1024 do
      ActionMailer::Base.deliveries.clear
      assert_no_difference "News.count" do
        assert_equal %w[create], sync(apply: false).map { |event| event[:action] }
      end
      sync
      news = imported
      assert_equal [@project.id, "Release 2.0", "What changes", 2], [news.project_id, news.title, news.summary, news.author_id]
      assert_equal Time.utc(2026, 3, 1, 9), news.created_on
      assert_equal 1, news.comments.size
      comment = news.comments.first
      assert_equal [3, Time.utc(2026, 3, 2, 10)], [comment.author_id, comment.created_on]
      assert_equal 1, news.reload.comments_count
      assert_equal 1, news.attachments.size
      attachment = news.attachments.first
      assert_equal ["plan.txt", 2], [attachment.filename, attachment.author_id]
      assert_equal FILE, File.read(attachment.diskfile)
      assert_equal ["mirror/source/attachments/901/download"], @source.downloads
      assert_empty ActionMailer::Base.deliveries
    end
    assert_equal %w[unchanged], sync.map { |event| event[:action] }
  end

  def test_new_and_edited_comments_and_new_files_update_the_news
    with_settings attachment_max_size: 1024 do
      sync
      item = @source.news.first
      item["comments"].first["content"] = "Great news, edited"
      item["comments"] << item["comments"].first.merge("id" => 802, "content" => "Second")
      item["attachments"] << item["attachments"].first.merge("id" => 902, "filename" => "annex.txt")
      assert_equal %w[update], sync.map { |event| event[:action] }
      assert_equal ["Great news, edited", "Second"], imported.comments.order(:id).map(&:comments)
      assert_equal %w[annex.txt plan.txt], imported.attachments.map(&:filename).sort
      assert_equal %w[unchanged], sync.map { |event| event[:action] }
    end
  end

  def test_anonymized_author_is_the_anonymous_user
    @mappings = { "user" => { "7" => "anonymous", "8" => "anonymous" } }
    with_settings attachment_max_size: 1024 do
      @source.news.first["attachments"] = []
      sync
      assert_equal [User.anonymous.id], [imported.author_id, *imported.comments.map(&:author_id)].uniq
    end
  end

  def test_local_edit_is_a_conflict_unless_the_source_wins
    with_settings attachment_max_size: 1024 do
      sync
      imported.update!(title: "Local title")
      error = assert_raises(RedmineMirror::Error) { sync }
      assert_match(/Local modification detected for news "Release 2.0"/, error.message)
      RedmineMirror::Policy.with(source_wins: true) { sync }
      assert_equal "Release 2.0", imported.title
    end
  end

  def test_mirror_mode_removes_comments_and_files_gone_from_the_source
    with_settings attachment_max_size: 1024 do
      sync
      @source.news.first["comments"] = []
      @source.news.first["attachments"] = []
      RedmineMirror::Policy.with(source_wins: true) { sync }
      assert_empty imported.comments
      assert_empty imported.attachments
    end
  end

  def test_deletion_is_confirmed_by_the_source
    with_settings attachment_max_size: 1024 do
      sync
      news = imported
      assert_equal "deleted", @adapter.source_state(@source, 61, news.id, source_project_id: 9, project_id: @project.id)
      @adapter.delete_local(news.id, @project.id)
      assert_nil News.find_by(id: news.id)
    end
  end

  def test_missing_mapping_disabled_module_and_source_without_mirror_fail
    @mappings = { "user" => { "7" => "2" } }
    assert_match(/Missing user mapping for source ID 8/, assert_raises(RedmineMirror::Error) { sync(apply: false) }.message)
    @project.disable_module!(:news)
    @mappings = { "user" => { "7" => "2", "8" => "3" } }
    assert_match(/Enable the News module/, assert_raises(RedmineMirror::Error) { sync(apply: false) }.message)
    source = Object.new
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"; end
    assert_match(/install Redmine Mirror 1.0.0-beta.26/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path} (Mirror source: not_shared)"; end
    assert_match(/Share News/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path}"; end
    assert_match(/needs View news/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
  end

  def test_catalog_lists_authors_of_news_comments_and_files
    catalog = RedmineMirror::SourceCatalog.new(client: Class.new(Source) { def get(path, params = {}); path == "projects/9.json" ? {} : super; end }.new,
      project_id: 9, adapters: [RedmineMirror::Adapters::Users.new, @adapter]).fetch
    assert_equal %w[7 8], catalog.fetch("user").keys.sort
  end
end
