# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_source_api_test.rb
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
# Verify the Mirror source API: its three locks, the account permission and the access log.

require_relative "../test_helper"

class MirrorSourceApiTest < Redmine::ApiTest::Base
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules,
    :documents, :enumerations, :attachments, :news, :comments, :queries

  SESSION = "0123456789abcdef0123456789abcdef"

  def setup
    super
    set_tmp_attachments_directory
    @project = Project.find(1)
    @project.enable_module!(:mirror_source)
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents])
  end

  def mirror_headers(user = "jsmith", password = nil)
    credentials(user, password).merge("X-Mirror-Session" => SESSION, "X-Mirror-Purpose" => "synchronization")
  end

  def enabled(&block)
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1" }, &block)
  end

  def test_lists_shows_and_downloads_shared_documents_and_logs_each_access
    enabled do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :success
      documents = JSON.parse(response.body)
      assert_equal 3, documents.fetch("total_count")
      first = documents.fetch("documents").first
      assert_equal [1, "Test document", "Document description"], first.values_at("id", "title", "description")
      assert_equal({ "id" => 1, "name" => "Uncategorized" }, first.fetch("category"))
      assert_equal %w[document.txt picture.jpg], first.fetch("attachments").map { |attachment| attachment.fetch("filename") }
      get "/mirror/source/documents/3.json", headers: mirror_headers
      assert_equal({ "id" => 3, "name" => "Technical documentation" }, JSON.parse(response.body).dig("document", "category"))
      # Fixture files are not on disk: attach a real one.
      file = Attachment.create!(container: Document.find(1), file: uploaded_test_file("testfile.txt", "text/plain"), author: User.find(2))
      get "/mirror/source/attachments/#{file.id}/download", headers: mirror_headers
      assert_response :success
      assert_equal File.binread(file.diskfile), response.body
    end
    accesses = MirrorSourceAccess.where(session_key: SESSION).order(:id).to_a
    assert_equal %w[list show download], accesses.map(&:action)
    assert_equal [@project.id], accesses.map(&:project_id).uniq
    assert_equal [2], accesses.map(&:user_id).uniq
    assert_equal ["synchronization"], accesses.map(&:purpose).uniq
    assert_equal 3, accesses.first.object_count
    assert_equal "testfile.txt", accesses.last.details.dig("attachment", "filename")
    # One session (not `sole`: Redmine 5.1 runs Rails 6.1).
    sessions = @project.mirror_source_accesses.sessions.to_a
    assert_equal 1, sessions.size
    session = sessions.first
    assert_equal [3, 3, 1, 0], [session.requests, session.documents, session.files, session.refused]
  end

  # News share their own lock: comments and files come with them, logged as documents are.
  def test_lists_shows_and_downloads_shared_news_with_comments
    file = nil
    enabled do
      get "/projects/ecookbook/mirror/source/news.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "not_shared", response.headers["X-Mirror-Source-Refusal"]
      @project.mirror_source_setting.update!(shared_modules: %w[documents news])
      get "/projects/ecookbook/mirror/source/news.json", headers: mirror_headers
      assert_response :success
      listed = JSON.parse(response.body).fetch("news")
      assert_equal @project.news.order(:id).pluck(:id), listed.map { |item| item.fetch("id") }
      first = listed.first
      news = News.find(first.fetch("id"))
      assert_equal [news.title, news.summary, news.description, news.author_id], first.values_at("title", "summary", "description").push(first.dig("author", "id"))
      assert_equal news.comments.map(&:comments), first.fetch("comments").map { |comment| comment.fetch("content") }
      get "/mirror/source/news/#{news.id}.json", headers: mirror_headers
      assert_equal news.title, JSON.parse(response.body).dig("news", "title")
      file = Attachment.create!(container: news, file: uploaded_test_file("testfile.txt", "text/plain"), author: User.find(2))
      get "/mirror/source/attachments/#{file.id}/download", headers: mirror_headers
      assert_response :success
      assert_equal File.binread(file.diskfile), response.body
      # Shared news do not open document files, and the reverse.
      @project.mirror_source_setting.update!(shared_modules: %w[news])
      document_file = Attachment.create!(container: Document.find(1), file: uploaded_test_file("testfile.txt", "text/plain"), author: User.find(2))
      get "/mirror/source/attachments/#{document_file.id}/download", headers: mirror_headers
      assert_equal "not_shared", response.headers["X-Mirror-Source-Refusal"]
      # View news is not public: without it, the account is refused.
      Role.all.each { |role| role.remove_permission!(:view_news) }
      get "/projects/ecookbook/mirror/source/news.json", headers: mirror_headers
      assert_equal "permission", response.headers["X-Mirror-Source-Refusal"]
    end
    assert_equal %w[refused list show download refused refused], MirrorSourceAccess.where(session_key: SESSION).order(:id).pluck(:action)
    assert_equal file.id, MirrorSourceAccess.find_by(action: "download").details.dig("attachment", "id")
  end

  # Tags need the Redmine Tags plugin on the source: without it, the shared kind answers
  # 404 and names the missing piece.
  def test_issue_tags_need_the_tags_plugin_on_the_source
    skip "Redmine Tags is installed" if RedmineMirror::Source.tags_available?
    enabled do
      @project.mirror_source_setting.update!(shared_modules: %w[issue_tags])
      get "/projects/ecookbook/mirror/source/issue_tags.json", headers: mirror_headers
      assert_response :not_found
      assert_equal "unavailable", response.headers["X-Mirror-Source-Refusal"]
      # The missing plugin is named before any other lock.
      @project.mirror_source_setting.update!(shared_modules: [])
      get "/projects/ecookbook/mirror/source/issue_tags.json", headers: mirror_headers
      assert_equal "unavailable", response.headers["X-Mirror-Source-Refusal"]
    end
  end

  # Scrum sprints need the Scrum plugin on the source.
  def test_scrum_needs_the_scrum_plugin_on_the_source
    skip "Scrum is installed" if RedmineMirror::Source.scrum_available?
    enabled do
      @project.mirror_source_setting.update!(shared_modules: %w[scrum])
      get "/projects/ecookbook/mirror/source/scrum.json", headers: mirror_headers
      assert_response :not_found
      assert_equal "unavailable", response.headers["X-Mirror-Source-Refusal"]
    end
  end

  # Saved queries: every query of the project, private ones of other users included,
  # with plain JSON definitions; queries of other projects never.
  def test_lists_the_project_saved_queries
    enabled do
      @project.mirror_source_setting.update!(shared_modules: %w[queries])
      get "/projects/ecookbook/mirror/source/queries.json", headers: mirror_headers
      assert_response :success
      listed = JSON.parse(response.body).fetch("queries")
      expected = Query.where(project_id: @project.id, type: %w[IssueQuery TimeEntryQuery]).order(:id)
      assert_equal expected.pluck(:id), listed.map { |row| row.fetch("id") }
      assert listed.any? { |row| row["visibility"] == Query::VISIBILITY_PRIVATE && row.dig("user", "id") != 2 }
      first = listed.find { |row| row.fetch("filters").any? }
      assert_equal %w[operator values], first.fetch("filters").values.first.keys.sort
    end
    assert_equal "list", MirrorSourceAccess.where(session_key: SESSION).last.action
  end

  # Each lock refuses with its reason, logged; the destination reads the header.
  def test_each_lock_refuses_and_names_itself
    get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
    assert_response :forbidden
    assert_equal "disabled", response.headers["X-Mirror-Source-Refusal"]
    enabled do
      @project.mirror_source_setting.update!(shared_modules: [])
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_equal "not_shared", response.headers["X-Mirror-Source-Refusal"]
      @project.disable_module!(:mirror_source)
      get "/mirror/source/documents/1.json", headers: mirror_headers
      assert_equal "module", response.headers["X-Mirror-Source-Refusal"]
      @project.reload.enable_module!(:mirror_source)
      @project.mirror_source_setting.update!(shared_modules: %w[documents])
      Role.find(1).remove_permission!(:view_documents)
      get "/mirror/source/attachments/2/download", headers: mirror_headers
      assert_response :forbidden
      assert_equal "permission", response.headers["X-Mirror-Source-Refusal"]
    end
    assert_equal %w[disabled not_shared module permission], MirrorSourceAccess.where(action: "refused").order(:id).pluck(:reason)
  end

  # Projects the account cannot see, missing objects and other files reveal nothing.
  def test_invisible_projects_missing_objects_and_other_files
    enabled do
      Project.find(2).enable_module!(:mirror_source)
      get "/projects/onlinestore/mirror/source/documents.json", headers: mirror_headers("dlopper", "foo")
      assert_response :forbidden
      assert_nil response.headers["X-Mirror-Source-Refusal"]
      get "/mirror/source/documents/999.json", headers: mirror_headers
      assert_response :not_found
      # Attachment 1 belongs to an issue: only document files are served.
      get "/mirror/source/attachments/1/download", headers: mirror_headers
      assert_response :not_found
      get "/projects/ecookbook/mirror/source/documents.json"
      assert_response :unauthorized
    end
    assert_equal 0, MirrorSourceAccess.where(project_id: 2).count
  end

  def test_sessions_without_header_are_grouped_per_account_address_and_day
    enabled do
      2.times { get "/projects/ecookbook/mirror/source/documents.json", headers: credentials("jsmith") }
    end
    assert_equal 1, MirrorSourceAccess.distinct.count(:session_key)
    assert_nil MirrorSourceAccess.first.purpose
  end
end
