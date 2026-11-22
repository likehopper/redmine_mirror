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
    :documents, :enumerations, :attachments, :news, :comments, :queries, :issue_categories, :repositories, :changesets, :issues,
    :trackers, :projects_trackers, :custom_fields, :custom_fields_projects, :custom_fields_trackers, :time_entries, :issue_statuses,
    :wikis, :wiki_pages, :wiki_contents

  SESSION = "0123456789abcdef0123456789abcdef"
  # Destinations up to 1.0.0-beta.50 send a consumer key.
  CONSUMER = "a" * 64
  # Integration requests come from the loopback; Mirror source needs an allowed address.
  LOOPBACK = "127.0.0.1"
  APPLICATION_KEY = "mirror-application-key-for-tests"

  def setup
    super
    set_tmp_attachments_directory
    @project = Project.find(1)
    @project.enable_module!(:mirror_source)
    reader_role = Role.find(1)
    %i[view_issues view_private_notes view_time_entries view_members].each { |permission| reader_role.add_permission!(permission) }
    reader_role.update!(issues_visibility: "all")
    reader_role.update!(time_entries_visibility: "all") if reader_role.respond_to?(:time_entries_visibility=)
    setting = MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents],
      client_addresses: "127.0.0.1\n10.0.0.0/8", authorized_user_ids: [2, 3])
    setting.update!(client_key: APPLICATION_KEY)
  end

  # As Mirror clients send them: the API key in its header (Source.api_key_request?).
  def mirror_headers(user = "jsmith", _password = nil)
    { "X-Redmine-API-Key" => User.find_by_login(user).api_key, "X-Mirror-Application-Key" => APPLICATION_KEY,
      "X-Mirror-Session" => SESSION, "X-Mirror-Purpose" => "synchronization" }
  end

  # Only the API key header authenticates; a password, a key in the URL or a session is
  # refused, as is any address outside the administrator's list.
  def test_only_the_api_key_header_from_an_allowed_address_is_served
    enabled do
      get "/projects/ecookbook/mirror/source/documents.json", headers: credentials("jsmith")
      assert_response :forbidden
      assert_equal "api_key", response.headers["X-Mirror-Source-Refusal"]
      get "/projects/ecookbook/mirror/source/documents.json", params: { key: User.find_by_login("jsmith").api_key }
      assert_equal "api_key", response.headers["X-Mirror-Source-Refusal"]
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :success
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "10.0.0.0/8\n192.168.1.12" }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "address", response.headers["X-Mirror-Source-Refusal"]
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "10.0.0.0/8\n127.0.0.0/8" }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :success
    end
    # Behind a reverse proxy on this host, the address it forwards is the caller's.
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "10.1.2.0/24" }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.merge("X-Forwarded-For" => "192.168.9.9, 10.1.2.3")
      assert_response :success
      assert_equal "10.1.2.3", MirrorSourceAccess.order(:id).last.remote_ip
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.merge("X-Forwarded-For" => "10.1.2.3, 192.168.9.9")
      assert_equal "address", response.headers["X-Mirror-Source-Refusal"]
    end
    # Without any allowed address, Mirror source stays off: an API key alone never opens it.
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "" }) do
      assert_not RedmineMirror::Source.enabled?
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "disabled", response.headers["X-Mirror-Source-Refusal"]
    end
    # A proxy on another host: its header counts only once it is trusted.
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "10.1.2.3" }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.merge("X-Forwarded-For" => "10.1.2.3"), env: { "REMOTE_ADDR" => "10.9.9.9" }
      assert_equal "address", response.headers["X-Mirror-Source-Refusal"]
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "10.1.2.3", "source_trusted_proxies" => "10.9.9.0/24" }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.merge("X-Forwarded-For" => "192.168.9.9, 10.1.2.3"), env: { "REMOTE_ADDR" => "10.9.9.9" }
      assert_response :success
      assert_equal "10.1.2.3", MirrorSourceAccess.order(:id).last.remote_ip
      # Through this host's proxy, then the trusted one.
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.merge("X-Forwarded-For" => "10.1.2.3, 10.9.9.9")
      assert_response :success
      # A spoofed header from an untrusted caller is ignored.
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.merge("X-Forwarded-For" => "10.1.2.3"), env: { "REMOTE_ADDR" => "10.8.8.8" }
      assert_equal "address", response.headers["X-Mirror-Source-Refusal"]
    end
    # A typo never opens the source: no valid entry, no address.
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "127.0.0.x" }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_equal "address", response.headers["X-Mirror-Source-Refusal"]
    end
  end

  def test_project_client_address_and_account_are_both_required
    enabled do
      @project.mirror_source_setting.update!(client_addresses: "192.0.2.10")
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "client_address", response.headers["X-Mirror-Source-Refusal"]

      @project.mirror_source_setting.update!(client_addresses: "127.0.0.1", authorized_user_ids: [])
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "client_user", response.headers["X-Mirror-Source-Refusal"]
    end
    assert_equal %w[client_address client_user], MirrorSourceAccess.where(action: "refused").order(:id).pluck(:reason)
  end

  def test_project_application_key_is_required_and_compared_without_storing_it
    enabled do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.except("X-Mirror-Application-Key")
      assert_response :forbidden
      assert_equal "client_key", response.headers["X-Mirror-Source-Refusal"]
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.merge("X-Mirror-Application-Key" => "wrong")
      assert_response :forbidden
      assert_equal "client_key", response.headers["X-Mirror-Source-Refusal"]
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :success
    end
    refute_includes @project.mirror_source_setting.client_key_digest, APPLICATION_KEY
  end

  def test_client_authorization_is_scoped_to_the_requested_project
    other = Project.find(3)
    other.enable_module!(:mirror_source)
    other.enable_module!(:documents)
    MirrorSourceSetting.create!(project: other, shared_modules: %w[documents])
    enabled do
      get "/projects/subproject1/mirror/source/documents.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "client_address", response.headers["X-Mirror-Source-Refusal"]
    end
  end

  def test_incremental_feed_is_refused_when_the_account_cannot_see_every_private_change
    Role.find(1).remove_permission!(:view_private_notes)
    enabled do
      get "/projects/ecookbook/mirror/source/changes.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "incremental_visibility", response.headers["X-Mirror-Source-Refusal"]
    end
  end

  # The destination keeps its position: reading the journal writes nothing on the source.
  def test_changes_are_read_after_the_position_the_destination_keeps
    issue = @project.issues.first
    enabled do
      get "/projects/ecookbook/mirror/source/changes.json", headers: mirror_headers
      start = JSON.parse(response.body)
      assert start.fetch("full_required")
      issue.update!(subject: "Changed for incremental Mirror")
      assert_no_difference -> { MirrorSourceChange.count + MirrorSourceChangeState.count } do
        get "/projects/ecookbook/mirror/source/changes.json", params: { after: start.fetch("cursor") }, headers: mirror_headers
        assert_response :success
        page = JSON.parse(response.body)
        assert_not page.fetch("full_required")
        issue_change = page.fetch("changes").find { |change| change["module_key"] == "issue_tracking" }
        assert_equal [issue.id, "upsert"], issue_change.values_at("source_id", "action")
        assert_equal page.fetch("high_water"), page.fetch("cursor")

        get "/projects/ecookbook/mirror/source/changes.json", params: { after: page.fetch("cursor") }, headers: mirror_headers
        assert_empty JSON.parse(response.body).fetch("changes")
      end
    end
  end

  # Before the kept journal, or after its end (a restored source database), a destination
  # cannot trust its position.
  def test_positions_outside_the_kept_journal_ask_for_a_complete_pass
    @project.issues.first.update!(subject: "Journaled")
    high_water = MirrorSourceChange.where(project_id: @project.id).maximum(:id)
    MirrorSourceChangeState.create!(project: @project, discarded_before_id: high_water)
    enabled do
      [high_water - 1, high_water + 1].each do |after|
        get "/projects/ecookbook/mirror/source/changes.json", params: { after: after }, headers: mirror_headers
        assert JSON.parse(response.body).fetch("full_required"), "position #{after}"
      end
      get "/projects/ecookbook/mirror/source/changes.json", params: { after: high_water }, headers: mirror_headers
      assert_not JSON.parse(response.body).fetch("full_required")
      get "/projects/ecookbook/mirror/source/changes.json", params: { after: -1 }, headers: mirror_headers
      assert_response :unprocessable_entity
    end
  end

  # Destinations up to 1.0.0-beta.50 expect the source to keep their acknowledgements:
  # they get the answer of a source without the journal and use their compatible mode.
  def test_destinations_sending_a_consumer_key_get_the_compatible_answer
    enabled do
      get "/projects/ecookbook/mirror/source/changes.json", params: { consumer: CONSUMER }, headers: mirror_headers
      assert_response :not_found
    end
  end

  # dlopper's role sees public issues only, no private notes, and no time entry of a
  # project where he is not a member (time entries follow project permissions in Redmine).
  def test_changes_of_objects_the_api_account_cannot_see_are_left_out
    private_issue = @project.issues.where(is_private: false).where.not(author_id: 3).where("assigned_to_id IS NULL OR assigned_to_id <> 3").first!
    private_issue.update_columns(is_private: true)
    public_issue = @project.issues.where(is_private: false).first!
    private_note = public_issue.journals.create!(user: User.find(2), notes: "Hidden", private_notes: true)
    public_note = public_issue.journals.create!(user: User.find(2), notes: "Shown")
    after = MirrorSourceChange.where(project_id: @project.id).maximum(:id).to_i
    private_issue.update_columns(subject: "Still private")
    RedmineMirror::SourceChanges.record(@project.id, "issue_tracking", private_issue.id)
    RedmineMirror::SourceChanges.record(@project.id, "issue_watchers", private_issue.id, parent_id: private_issue.id)
    RedmineMirror::SourceChanges.record(@project.id, "issue_tracking", 999_999, action: "delete")
    [private_note, public_note].each do |journal|
      RedmineMirror::SourceChanges.record(@project.id, "issue_journals", journal.id, parent_id: public_issue.id)
    end
    hidden_time = TimeEntry.new(project: Project.find(5), user: User.find(2), hours: 1,
      activity: TimeEntryActivity.first, spent_on: Date.today)
    hidden_time.save!(validate: false)
    RedmineMirror::SourceChanges.record(@project.id, "time_tracking", hidden_time.id)

    changes = RedmineMirror::SourceChanges.page(@project, after: after, user: User.find(3)).fetch(:changes)
    seen = changes.map { |change| change.values_at("module_key", "source_id", "action") }
    assert_includes seen, ["issue_tracking", 999_999, "delete"]
    assert_includes seen, ["issue_journals", public_note.id, "upsert"]
    refute seen.any? { |key, id, _| [["issue_tracking", private_issue.id], ["issue_watchers", private_issue.id],
      ["issue_journals", private_note.id], ["time_tracking", hidden_time.id]].include?([key, id]) }, seen.inspect
    jsmith = RedmineMirror::SourceChanges.page(@project, after: after, user: User.find(2)).fetch(:changes)
    assert jsmith.any? { |change| change.values_at("module_key", "source_id") == ["issue_tracking", private_issue.id] }
  end

  # A file attached to a wiki page keeps the page version: the journal names the page
  # by its title key, so that destinations read that page's detail again.
  def test_files_attached_to_wiki_pages_are_journaled_for_their_page
    page = @project.wiki.pages.first!
    file = Attachment.create!(container: page, file: uploaded_test_file("testfile.txt", "text/plain"), author: User.find(2))
    file.destroy!
    changes = MirrorSourceChange.where(project_id: @project.id, module_key: "wiki",
      source_id: RedmineMirror::Adapters::Wiki.source_id(page.title))
    assert_equal 2, changes.count
    enabled do
      get "/projects/ecookbook/mirror/source/changes.json", params: { after: 0 }, headers: mirror_headers
      assert_response :success
      assert_equal %w[wiki], JSON.parse(response.body).fetch("journaled_modules")
    end
  end

  def test_destroying_a_project_removes_its_incremental_protocol_state
    project = Project.create!(name: "Disposable Mirror source", identifier: "disposable-mirror-source")
    MirrorSourceChange.create!(project: project, module_key: "issue_tracking", source_id: 1, action: "upsert", created_at: Time.current)
    MirrorSourceChangeState.create!(project: project)
    MirrorSyncRetry.create!(project: project, connection_key: "b" * 64,
      module_key: "issue_tracking", source_id: 1)

    project.destroy!

    [MirrorSourceChange, MirrorSourceChangeState, MirrorSyncRetry].each do |model|
      assert_not model.exists?(project_id: project.id), "#{model.name} kept an orphan row"
    end
  end

  def test_incremental_tables_accept_synthetic_64_bit_source_identifiers
    synthetic_id = 83_953_617_425_747_053
    assert MirrorProjectSetting.bigint_identifiers?

    change = MirrorSourceChange.create!(project: @project, module_key: "wiki", source_id: synthetic_id,
      parent_id: synthetic_id, action: "upsert", created_at: Time.current)
    retry_record = MirrorSyncRetry.create!(project: @project, connection_key: "c" * 64,
      module_key: "wiki", source_id: synthetic_id, parent_id: synthetic_id)

    assert_equal synthetic_id, change.reload.source_id
    assert_equal synthetic_id, retry_record.reload.source_id
  end

  def test_projects_without_mirror_source_settings_keep_no_journal
    issue = Issue.where.not(project_id: @project.id).first!
    assert_not MirrorSourceSetting.exists?(project_id: issue.project_id)
    assert_no_difference -> { MirrorSourceChange.count } do
      issue.update!(subject: "Not journaled outside Mirror source")
      issue.journals.create!(user: User.find(2), notes: "Not journaled either")
    end
  end

  def test_a_suspended_journal_records_nothing_and_answers_like_a_source_without_it
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_changes_enabled" => "0" }) do
      assert_no_difference -> { MirrorSourceChange.count } do
        @project.issues.first.update!(subject: "Changed while the journal is suspended")
      end
      # A 404 on this path is the destination's signal to use its compatible mode.
      get "/projects/ecookbook/mirror/source/changes.json", params: { after: 0 }, headers: mirror_headers
      assert_response :not_found
    end
  end

  # The marker of a gap is newer than every position a destination holds.
  def test_switching_the_journal_asks_every_destination_for_a_complete_pass
    @project.issues.first.update!(subject: "Recorded before the suspension")
    position = MirrorSourceChange.where(project_id: @project.id).maximum(:id)
    # with_settings restores the settings (and their cache) that the form saves.
    enabled do
      log_user("admin", "admin")
      post "/settings/plugin/redmine_mirror", params: { settings: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_changes_enabled" => "0" } }
      post "/settings/plugin/redmine_mirror", params: { settings: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_changes_enabled" => "1" } }
      reset!

      get "/projects/ecookbook/mirror/source/changes.json", params: { after: position }, headers: mirror_headers
      page = JSON.parse(response.body)
      assert page.fetch("full_required")
      # The complete pass keeps the position given with the request.
      get "/projects/ecookbook/mirror/source/changes.json", params: { after: page.fetch("cursor") }, headers: mirror_headers
      page = JSON.parse(response.body)
      assert_not page.fetch("full_required")
      refute page.fetch("changes").any? { |change| change["module_key"] == RedmineMirror::SourceChanges::RESYNC_KEY }
    end
  end

  def test_saving_the_settings_without_switching_the_journal_keeps_destinations_incremental
    enabled do
      log_user("admin", "admin")
      assert_no_difference -> { MirrorSourceChange.count } do
        post "/settings/plugin/redmine_mirror", params: { settings: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_changes_enabled" => "1" } }
      end
    end
  end

  # The journal itself fails: the gap still moves past its last entry.
  def test_a_journal_failure_neither_fails_the_save_nor_hides_the_gap
    issue = @project.issues.first
    issue.update!(subject: "Journaled before the failure")
    position = MirrorSourceChange.where(project_id: @project.id).maximum(:id)
    MirrorSourceChange.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "journal unavailable" }) do
      issue.update!(subject: "Saved despite the journal")
      issue.destroy
    end
    assert issue.destroyed?
    assert_not Issue.exists?(issue.id)
    page = RedmineMirror::SourceChanges.page(@project, after: position, user: User.find(2))
    assert page.fetch(:full_required)
  end

  def test_a_browser_session_is_refused
    log_user("jsmith", "jsmith")
    enabled { get "/projects/ecookbook/mirror/source/documents.json" }
    assert_response :forbidden
    assert_equal "api_key", response.headers["X-Mirror-Source-Refusal"]
  end

  def test_localizable_names_are_read_without_sharing_its_configuration
    settings = { "locales" => { "tracker" => { "1" => { "fr" => "Anomalie" } },
      "issue_status" => { "1" => { "fr" => "Nouveau" } } } }
    settings["locales"]["tracker"]["999"] = { "fr" => "Hors projet" }
    # Keep both a project tracker and an unrelated configured ID: only usable references
    # may leave the source.
    RedmineMirror::LocalizedNames.stub(:localizable_settings, settings) do
      with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK }) do
        get "/projects/ecookbook/mirror/source/localized_names.json", headers: mirror_headers
        assert_response :success
        names = JSON.parse(response.body).fetch("localized_names")
        assert_equal [Tracker.find(1)[:name], "Anomalie"], names.dig("tracker", "1")
        assert_nil names.dig("tracker", "999")
        assert_nil names["locales"]
      end
    end
    access = MirrorSourceAccess.where(session_key: SESSION).last
    assert_equal ["list", { "kind" => "localized_names" }], [access.action, access.details]
  end

  # Explicit kinds (Source::EXPLICIT_KINDS) need the administrator's choice.
  def enabled(*explicit_kinds, &block)
    settings = { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK }
    settings["source_kinds"] = RedmineMirror::Source.available_kinds - RedmineMirror::Source::EXPLICIT_KINDS + explicit_kinds if explicit_kinds.any?
    with_settings(plugin_redmine_mirror: settings, &block)
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
    assert_equal({ "kind" => "documents" }, accesses.last.details)
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
    assert_equal({ "kind" => "news" }, MirrorSourceAccess.find_by(action: "download").details)
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

  # Saved queries: public ones and those limited to roles the account can see, with plain
  # JSON definitions; private queries never, the account's own included, nor queries of
  # other projects.
  def test_lists_the_project_saved_queries
    own = IssueQuery.create!(project: @project, user: User.find(2), name: "Own private", visibility: Query::VISIBILITY_PRIVATE)
    hidden = IssueQuery.create!(project: @project, user: User.find(1), name: "Other roles", visibility: Query::VISIBILITY_ROLES,
      roles: [Role.find(3)])
    enabled("queries") do
      @project.mirror_source_setting.update!(shared_modules: %w[queries])
      get "/projects/ecookbook/mirror/source/queries.json", headers: mirror_headers
      assert_response :success
      listed = JSON.parse(response.body).fetch("queries")
      expected = Query.where(project_id: @project.id, type: %w[IssueQuery TimeEntryQuery]).where.not(visibility: Query::VISIBILITY_PRIVATE)
        .order(:id).select { |query| query.visible?(User.find(2)) }
      assert expected.any?
      assert_equal expected.map(&:id), listed.map { |row| row.fetch("id") }
      assert listed.none? { |row| row["visibility"] == Query::VISIBILITY_PRIVATE }
      assert_not_includes listed.map { |row| row["id"] }, own.id
      assert_not_includes listed.map { |row| row["id"] }, hidden.id
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
    # Redmine hides new users' emails by default (default_users_hide_mail).
    User.find(2).pref.update!(hide_mail: false)
    enabled("users") do
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
    assert_equal({ "kind" => "users" }, access.details)
  end

  # An email its owner hides is never sent; a destination recognizes the account only from
  # the digest of an address it already knows.
  def test_hidden_emails_are_matched_from_digests_only
    dlopper = User.find(3)
    dlopper.pref.update!(hide_mail: true)
    User.find(2).pref.update!(hide_mail: false)
    digest = ->(address) { Digest::SHA256.hexdigest(address.downcase) }
    @project.mirror_source_setting.update!(shared_modules: %w[users])
    enabled("users") do
      get "/projects/ecookbook/mirror/source/users.json", params: { ids: "2,3" }, headers: mirror_headers
      listed = JSON.parse(response.body).fetch("users").index_by { |row| row["id"] }
      assert_equal "jsmith@somenet.foo", listed[2]["mail"]
      assert_nil listed[3]["mail"]
      assert listed[3]["mail_hidden"]
      assert_not_includes response.body, dlopper.mail

      digests = [digest.call(dlopper.mail.upcase), digest.call("someone@example.invalid"), "not-a-digest"]
      post "/projects/ecookbook/mirror/source/users/matches.json", params: { ids: "3,999", digests: digests },
        headers: mirror_headers, as: :json
      assert_response :success
      assert_equal [{ "id" => 3, "digest" => digest.call(dlopper.mail) }], JSON.parse(response.body).fetch("matches")
      assert_not_includes response.body, dlopper.mail
      assert_equal ["match", 1], MirrorSourceAccess.order(:id).last.then { |access| [access.action, access.object_count] }

      post "/projects/ecookbook/mirror/source/users/matches.json",
        params: { ids: "3", digests: Array.new(1_001) { |index| digest.call("user#{index}@example.invalid") } },
        headers: mirror_headers, as: :json
      assert_response :unprocessable_entity
      @project.mirror_source_setting.update!(shared_modules: [])
      post "/projects/ecookbook/mirror/source/users/matches.json", params: { ids: "3", digests: digests },
        headers: mirror_headers, as: :json
      assert_equal "not_shared", response.headers["X-Mirror-Source-Refusal"]
    end
  end

  # An administrator bypasses every permission: Mirror source requires a dedicated account.
  def test_administrators_api_keys_are_refused
    enabled do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers("admin")
      assert_response :forbidden
      assert_equal "admin_account", response.headers["X-Mirror-Source-Refusal"]
    end
  end

  # Before the administrator saves a choice, personal data and repositories stay refused
  # even when the project shares them.
  def test_personal_data_and_repositories_need_the_administrators_explicit_choice
    @project.mirror_source_setting.update!(shared_modules: %w[queries users repositories])
    enabled do
      %w[queries users repositories].each do |path|
        get "/projects/ecookbook/mirror/source/#{path}.json", params: { ids: "2" }, headers: mirror_headers
        assert_response :forbidden
        assert_equal "disabled", response.headers["X-Mirror-Source-Refusal"], path
      end
    end
  end

  # A participant of a private issue the API account cannot see is not revealed.
  def test_users_are_found_only_in_data_the_api_account_can_see
    stranger = User.generate!
    Issue.generate!(project: @project, author: stranger, is_private: true)
    @project.mirror_source_setting.update!(shared_modules: %w[users])
    enabled("users") do
      get "/projects/ecookbook/mirror/source/users.json", params: { ids: stranger.id.to_s }, headers: mirror_headers("dlopper")
      assert_response :success
      assert_empty JSON.parse(response.body).fetch("users")
      get "/projects/ecookbook/mirror/source/users.json", params: { ids: stranger.id.to_s }, headers: mirror_headers("jsmith")
      assert_equal [stranger.id], JSON.parse(response.body).fetch("users").map { |row| row.fetch("id") }
    end
  end

  # Field definitions need an explicit administrator choice, then the project's choice.
  # A regular project API account receives only fields it can use and see.
  def test_lists_project_visible_custom_field_definitions_with_both_consents
    field = IssueCustomField.create!(name: "Migration choices", field_format: "list", possible_values: ["A", "B"],
      multiple: true, is_for_all: true, trackers: Tracker.all)
    outside = IssueCustomField.create!(name: "Other project", field_format: "string", is_for_all: false,
      projects: [Project.find(2)], trackers: Tracker.all)
    @project.mirror_source_setting.update!(shared_modules: %w[issue_custom_fields])

    enabled do
      get "/projects/ecookbook/mirror/source/custom_fields.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "disabled", response.headers["X-Mirror-Source-Refusal"]
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_kinds" => %w[issue_custom_fields] }) do
      get "/projects/ecookbook/mirror/source/custom_fields.json", headers: mirror_headers
      assert_response :success
      fields = JSON.parse(response.body).fetch("custom_fields")
      listed = fields.find { |row| row["id"] == field.id }
      assert_equal ["issue", "list", true], listed.values_at("customized_type", "field_format", "multiple")
      assert_equal [["A", "A"], ["B", "B"]], listed.fetch("possible_values").map { |value| value.values_at("value", "label") }
      refute_includes fields.map { |row| row["id"] }, outside.id

      Role.all.each { |role| role.remove_permission!(:view_issues) }
      get "/projects/ecookbook/mirror/source/custom_fields.json", headers: mirror_headers
      assert_equal "permission", response.headers["X-Mirror-Source-Refusal"]
    end
    access = MirrorSourceAccess.where(session_key: SESSION, action: "list").last
    assert_equal({ "kind" => "issue_custom_fields" }, access.details)
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
    enabled("repositories") do
      get "/projects/ecookbook/mirror/source/repositories.json", headers: mirror_headers
      assert_response :success
      row = JSON.parse(response.body).fetch("repositories").find { |entry| entry["id"] == 10 }
      assert_equal ["Subversion", repository.url], row.values_at("scm", "url")
      # Credentials stay refused unless allowed explicitly, even shared by the project.
      refute row.key?("password")
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_kinds" => %w[repositories repository_credentials] }) do
      # Allowed and shared, they are still sent only when asked for.
      get "/projects/ecookbook/mirror/source/repositories.json", headers: mirror_headers
      refute JSON.parse(response.body).fetch("repositories").find { |entry| entry["id"] == 10 }.key?("password")
      get "/projects/ecookbook/mirror/source/repositories.json", params: { credentials: "1" }, headers: mirror_headers
      row = JSON.parse(response.body).fetch("repositories").find { |entry| entry["id"] == 10 }
      assert_equal %w[svc secret], row.values_at("login", "password")
      setting.update!(shared_modules: %w[repositories])
      get "/projects/ecookbook/mirror/source/repositories.json", params: { credentials: "1" }, headers: mirror_headers
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
    # A source switched off refuses before reading any project: Redmine's log only.
    assert_equal %w[not_shared module permission], MirrorSourceAccess.where(action: "refused").order(:id).pluck(:reason)
  end

  # Data the administrator does not allow is refused like a disabled Mirror source,
  # even when the project shares it.
  def test_data_the_administrator_does_not_allow_is_refused
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_kinds" => ["", "news"] }) do
      get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers
      assert_response :forbidden
      assert_equal "disabled", response.headers["X-Mirror-Source-Refusal"]
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => LOOPBACK, "source_kinds" => ["documents"] }) do
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
      # Anonymous: refused before the project is even looked up.
      get "/projects/ecookbook/mirror/source/documents.json"
      assert_response :forbidden
      assert_equal "api_key", response.headers["X-Mirror-Source-Refusal"]
    end
    assert_equal 0, MirrorSourceAccess.where(project_id: 2).count
  end

  def test_sessions_without_header_are_grouped_per_account_address_and_day
    enabled do
      2.times { get "/projects/ecookbook/mirror/source/documents.json", headers: mirror_headers.except("X-Mirror-Session", "X-Mirror-Purpose") }
    end
    assert_equal 1, MirrorSourceAccess.distinct.count(:session_key)
    assert_nil MirrorSourceAccess.first.purpose
  end
end
