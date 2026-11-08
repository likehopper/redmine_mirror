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
    :documents, :enumerations, :attachments, :news, :comments, :queries, :issue_categories, :repositories, :changesets, :issues

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

  # Only the requested users the project knows (members, authors...), with their login,
  # email and company; the users API gives them to administrators only.
  def test_lists_the_requested_users_the_project_knows
    stranger = User.generate!
    ids = "2,3,#{stranger.id},999,x"
    company = UserCustomField.create!(name: "Company", field_format: "string")
    User.find(2).update!(custom_field_values: { company.id.to_s => "ACME" })
    enabled do
      get "/projects/ecookbook/mirror/source/users.json", params: { ids: ids }, headers: mirror_headers
      assert_equal "not_shared", response.headers["X-Mirror-Source-Refusal"]
      @project.mirror_source_setting.update!(shared_modules: %w[users])
      get "/projects/ecookbook/mirror/source/users.json", params: { ids: ids }, headers: mirror_headers
      assert_response :success
      listed = JSON.parse(response.body).fetch("users")
      # Members both; the new account appears nowhere in the project.
      assert_equal [2, 3], listed.map { |row| row.fetch("id") }
      jsmith = listed.find { |row| row["id"] == 2 }
      assert_equal ["jsmith", "John", "Smith", "jsmith@somenet.foo", "ACME"], jsmith.values_at("login", "firstname", "lastname", "mail", "company")
    end
    access = MirrorSourceAccess.where(session_key: SESSION).last
    assert_equal ["list", 2], [access.action, access.object_count]
    assert_equal [2, 3], access.details.fetch("users").map { |row| row["id"] }
  end

  # Each lock refuses with its reason, logged; the destination reads the header.
  # Categories with their sharing (when this Redmine has the column) and assignee: the
  # categories API lists them to managers only, without sharing.
  def test_lists_the_project_categories_with_their_sharing
    MirrorSourceSetting.find_by!(project: @project).update!(shared_modules: %w[issue_categories])
    enabled do
      get "/projects/ecookbook/mirror/source/issue_categories.json", headers: mirror_headers
      assert_response :success
      categories = JSON.parse(response.body).fetch("issue_categories")
      assert_equal IssueCategory.where(project_id: 1).order(:id).pluck(:id, :name), categories.map { |category| category.values_at("id", "name") }
      refute categories.first.key?("sharing")
      assert_equal "list", MirrorSourceAccess.where(session_key: SESSION).last.action
      begin
        ActiveRecord::Base.connection.add_column :issue_categories, :sharing, :string, limit: 40
        IssueCategory.reset_column_information
        IssueCategory.where(id: categories.first.fetch("id")).update_all(sharing: "descendants")
        get "/projects/ecookbook/mirror/source/issue_categories.json", headers: mirror_headers
        assert_equal ["descendants", "none"], JSON.parse(response.body).fetch("issue_categories").first(2).map { |category| category["sharing"] }
      ensure
        ActiveRecord::Base.connection.remove_column :issue_categories, :sharing
        IssueCategory.reset_column_information
      end
    end
  end

  # Project enumerations need their plugin on the source.
  def test_project_enumerations_need_the_plugin_on_the_source
    MirrorSourceSetting.find_by!(project: @project).update!(shared_modules: %w[project_enumerations])
    enabled do
      get "/projects/ecookbook/mirror/source/project_enumerations.json", headers: mirror_headers
      assert_response 404
      assert_equal "unavailable", response.headers["X-Mirror-Source-Refusal"]
    end
    extend MirrorFakeProjectEnumerations
    begin
      install_fake_project_enumerations
      MirrorSourceSetting.find_by!(project: @project).update!(shared_modules: %w[project_enumerations])
      field = enumeration_field("Client site")
      first = ProjectEnumeration.create!(project: @project, custom_field: field, value: "Paris", sharing: "descendants", position: 1)
      ProjectEnumeration.create!(project: Project.find(2), custom_field: field, value: "Elsewhere")
      enabled do
        get "/projects/ecookbook/mirror/source/project_enumerations.json", headers: mirror_headers
        assert_response :success
        rows = JSON.parse(response.body).fetch("project_enumerations")
        assert_equal [[first.id, "Paris", "descendants", 1]], rows.map { |row| row.values_at("id", "value", "sharing", "position") }
        assert_equal [field.id, "IssueCustomField"], rows.first.fetch("custom_field").values_at("id", "type")
        get "/mirror/source/project_enumerations/#{first.id}.json", headers: mirror_headers
        assert_equal "Paris", JSON.parse(response.body).dig("project_enumeration", "value")
        get "/mirror/source/project_enumerations/0.json", headers: mirror_headers
        assert_response 404
      end
    ensure
      remove_fake_project_enumerations
    end
  end

  # Repositories have no API; their credentials need the administrator's explicit choice
  # and the project's, and never reach the access log.
  def test_lists_repositories_with_credentials_only_when_both_allow_them
    repository = Repository.find(10)
    Changeset.where(repository_id: 10).order(:id).first.issues << Issue.find(1)
    repository.update_columns(login: "svc")
    repository.update!(password: "secret")
    setting = MirrorSourceSetting.find_by!(project: @project)
    setting.update!(shared_modules: %w[repositories repository_credentials])
    enabled do
      get "/projects/ecookbook/mirror/source/repositories.json", headers: mirror_headers
      assert_response :success
      row = JSON.parse(response.body).fetch("repositories").find { |entry| entry["id"] == 10 }
      assert_equal ["Subversion", repository.url], row.values_at("scm", "url")
      # Not allowed by default, even shared by the project.
      refute row.key?("password")
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_kinds" => %w[repositories repository_credentials] }) do
      get "/projects/ecookbook/mirror/source/repositories.json", headers: mirror_headers
      row = JSON.parse(response.body).fetch("repositories").find { |entry| entry["id"] == 10 }
      assert_equal %w[svc secret], row.values_at("login", "password")
      setting.update!(shared_modules: %w[repositories])
      get "/projects/ecookbook/mirror/source/repositories.json", headers: mirror_headers
      refute JSON.parse(response.body).fetch("repositories").first.key?("password")
      get "/mirror/source/repositories/10/links.json", params: { offset: 0 }, headers: mirror_headers
      assert_response :success
      links = JSON.parse(response.body).fetch("repository_links")
      expected = Changeset.where(repository_id: 10).joins(:issues).distinct.count
      assert_equal expected, links.fetch("total_count")
      first = links.fetch("links").first
      assert_equal Changeset.find_by!(repository_id: 10, revision: first.fetch("revision")).issue_ids.sort, first.fetch("issue_ids")
    end
    refute_match "secret", MirrorSourceAccess.where(session_key: SESSION).map { |access| access.details.to_json }.join
  end

  # Only subprojects running Mirror source that the account can see, at any depth, in
  # tree order; no data needs sharing, but the administrator and project locks apply.
  def test_lists_the_visible_subprojects_running_mirror_source
    get "/projects/ecookbook/mirror/source/subprojects.json", headers: mirror_headers
    assert_equal "disabled", response.headers["X-Mirror-Source-Refusal"]
    [3, 5, 6].each { |id| Project.find(id).enable_module!(:mirror_source) }
    enabled do
      get "/projects/ecookbook/mirror/source/subprojects.json", headers: mirror_headers
      assert_response :success
      subprojects = JSON.parse(response.body).fetch("subprojects")
      assert_equal [["private-child", 1], ["project6", 5], ["subproject1", 1]], subprojects.map { |child| child.values_at("identifier", "parent_id") }
      assert_includes subprojects.first.fetch("enabled_modules"), "mirror_source"
      # dlopper is no member of the private child: only the public subprojects.
      get "/projects/ecookbook/mirror/source/subprojects.json", headers: mirror_headers("dlopper", "foo")
      assert_equal %w[project6 subproject1], JSON.parse(response.body).fetch("subprojects").map { |child| child["identifier"] }
      @project.disable_module!(:mirror_source)
      get "/projects/ecookbook/mirror/source/subprojects.json", headers: mirror_headers
      assert_equal "module", response.headers["X-Mirror-Source-Refusal"]
    end
    assert_equal [3, 2], MirrorSourceAccess.where(action: "list").order(:id).pluck(:object_count)
  end

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

  # Data the administrator does not allow is refused like a disabled Mirror source,
  # even when the project shares it.
  def test_data_the_administrator_does_not_allow_is_refused
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_kinds" => ["", "news"] }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "disabled", response.headers["X-Mirror-Source-Refusal"]
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_kinds" => ["documents"] }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :success
    end
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
