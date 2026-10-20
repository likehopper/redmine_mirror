# frozen_string_literal: true
# File: redmine_mirror/test/documentation/configuration_test.rb
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
# Walk through doc/CONFIGURATION.md in a browser and regenerate its screenshots.
# Run it alone, against a seeded source Redmine and an empty destination database:
# test/documentation/run.sh prepares both in a container.

require File.expand_path("test/application_system_test_case", Dir.pwd)
require "socket"

class MirrorConfigurationDocumentationTest < ApplicationSystemTestCase
  # Steps follow the document: each one starts where the previous one left the database.
  i_suck_and_my_tests_are_order_dependent!
  self.use_transactional_tests = false
  self.fixture_table_names = []

  SCREENSHOTS = ENV.fetch("MIRROR_DOC_SCREENSHOTS") { Rails.root.join("tmp/redmine_mirror/screenshots").to_s }
  SOURCE_URL = ENV.fetch("MIRROR_SOURCE_URL")
  SOURCE_API_KEY = ENV.fetch("MIRROR_SOURCE_API_KEY")
  PROJECT = "mirror-demo"
  ADMIN_LOGIN = "mirror-doc-admin"
  ADMIN_PASSWORD = "Mirror-doc-123!"
  # Modules shown in the guide; the others are described in doc/MODULES.md.
  MODULES = %w[issue_categories project_versions issue_tracking time_tracking
               issue_journals issue_attachments issue_relations].freeze

  setup do
    prepare_destination unless self.class.instance_variable_get(:@prepared)
    self.class.instance_variable_set(:@prepared, true)
    # Redmine's system test case clears settings around each test; the worker
    # writes through the destination REST API, which step 2 enables.
    Setting.rest_api_enabled = "1"
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
  end

  def test_01_plugin_is_installed
    visit "/admin/plugins"
    assert_selector "tr#plugin-redmine_mirror"
    screenshot "01-admin-plugins", "#content"
  end

  def test_02_rest_api_is_enabled
    visit "/settings?tab=api"
    check "settings_rest_api_enabled"
    screenshot "02-rest-api", "#tab-content-api"
    within("#tab-content-api") { click_button "Save" }
    assert_selector "#flash_notice"
  end

  def test_03_source_is_allowed
    visit "/settings/plugin/redmine_mirror"
    fill_in "settings_allowed_source_urls", with: SOURCE_URL
    screenshot "03-allowed-sources", "#content"
    click_button "Apply"
    assert_selector "#flash_notice"
    assert RedmineMirror.allowed_source_url?(SOURCE_URL)
  end

  def test_04_roles_get_mirror_permissions
    role = Role.find_by!(name: "Manager")
    visit "/roles/#{role.id}/edit"
    fieldset = find("#role_permissions_view_mirror").ancestor("fieldset")
    %w[view_mirror run_mirror manage_mirror].each { |permission| fieldset.check("role_permissions_#{permission}") }
    screenshot "04-role-permissions", fieldset
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_05_project_enables_the_module
    visit "/projects/#{PROJECT}/settings/info"
    check "project_enabled_module_names_mirror"
    screenshot "05-project-modules", "#project_modules"
    within("#tab-content-info") { click_button "Save" }
    assert_selector "#flash_notice"
    assert_selector "#main-menu a.mirror"
    screenshot "06-project-menu", "#main-menu"
    within("#main-menu") { click_link "Mirror" }
    assert_selector "#mirror-step-connection.mirror-step-current"
    screenshot "07-getting-started", "#content"
  end

  def test_06_connection
    visit "/projects/#{PROJECT}/mirror"
    within("#mirror-setup") { click_link "Connect the source project" }
    assert_current_path "/projects/#{PROJECT}/settings/mirror"
    fill_in "connection_source_url", with: SOURCE_URL
    fill_in "connection_source_project_id", with: PROJECT
    fill_in "connection_api_key", with: SOURCE_API_KEY
    MODULES.each { |key| find("input[name='connection[modules][]'][value='#{key}']").check }
    screenshot "08-connection", "#tab-content-mirror"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_selector "#mirror-catalog-status"
    assert_empty MODULES - project.mirror_project_setting.selected_modules
    assert_no_text SOURCE_API_KEY
    # What the worker does next (rake redmine_mirror:tick).
    RedmineMirror::Synchronization.refresh_catalogs
    visit current_url
    assert_selector "#mirror-settings-subtabs .mirror-badge"
    screenshot "09-modules-to-map", "#mirror-settings-subtabs"
  end

  def test_07_user_mappings
    open_module_tab "users"
    map_by_name "user", "Redmine Admin" => "Anonymize"
    select "Mirror Archive", from: "anonymous-time-user"
    screenshot "10-users", "#tab-content-mirror"
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_08_issue_and_time_mappings
    open_module_tab "issue_tracking"
    # Local references with the same name are preselected: check, then save.
    assert_selector "#mirror-suggestions"
    screenshot "11-issues", "#tab-content-mirror"
    %w[tracker status priority].each { |table| map_by_name table }
    click_button "Save"
    assert_selector "#flash_notice"

    open_module_tab "time_tracking"
    map_by_name "activity"
    screenshot "12-time-tracking", "#tab-content-mirror"
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_09_relation_policy
    open_module_tab "issue_relations"
    select "Add a private note", from: "missing_target"
    screenshot "13-relations-policy", "#tab-content-mirror"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_no_selector "#mirror-settings-subtabs .mirror-badge"
  end

  def test_10_preview
    visit "/projects/#{PROJECT}/mirror"
    assert_selector "#mirror-step-preview.mirror-step-current"
    screenshot "14-overview", "#content"
    click_button "Run preview"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    assert project.issues.none?
    visit current_path
    screenshot "15-preview-log", "#content", max_height: 760
  end

  def test_11_import
    visit "/projects/#{PROJECT}/mirror"
    click_button "Synchronize now"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    assert_equal 12, project.issues.count
    visit current_path
    screenshot "16-import-log", "#content", max_height: 760
    # README illustration.
    screenshot "home", "#content", max_height: 520
    visit "/projects/#{PROJECT}/mirror"
    assert_no_selector "#mirror-setup"
    screenshot "17-overview-done", "#content"
  end

  def test_12_imported_data
    visit "/projects/#{PROJECT}/mirror?tab=objects"
    assert_selector "table.list tbody tr"
    screenshot "18-object-mappings", "#content", max_height: 760
    issue = project.issues.order(:id).first
    visit "/issues/#{issue.id}"
    assert_selector "#mirror-issue-origin"
    screenshot "19-imported-issue", "#content", max_height: 900
    visit "/projects/#{PROJECT}/mirror?tab=pending"
    assert_selector "#mirror-pending-relations tbody tr"
    screenshot "20-pending-links", "#content"
  end

  def test_13_schedule
    visit "/projects/#{PROJECT}/settings/mirror?mirror_tab=schedule"
    check "schedule-enabled"
    select "Every 60 minutes", from: "schedule-interval"
    click_button "Save"
    assert_selector "#flash_notice"
    assert project.mirror_project_setting.auto_sync_enabled?
    screenshot "21-schedule", find("#schedule-enabled").ancestor("form")
  end

  def test_14_history
    visit "/projects/#{PROJECT}/mirror?tab=history"
    assert_selector "#mirror-history tbody tr", count: 2
    screenshot "22-history", "#content"
  end

  def test_15_conflict
    # A destination user edits an imported issue: Mirror must not overwrite it.
    issue = project.issues.order(:id).first
    issue.init_journal(User.find_by!(login: "alice"))
    issue.update!(subject: "#{issue.subject} (edited locally)")
    visit "/projects/#{PROJECT}/mirror"
    click_button "Synchronize now"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "partial", run.status
    visit current_path
    screenshot "23-conflict-log", "#content", max_height: 460
    visit "/projects/#{PROJECT}/mirror?tab=conflicts"
    assert_selector "#mirror-conflicts tbody tr", count: 1
    screenshot "24-conflicts", "#content"
    accept_confirm { click_button "Keep local object" }
    assert_selector "#flash_notice"
    visit "/projects/#{PROJECT}/mirror?tab=conflicts&conflict_status=all"
    assert_selector "#mirror-conflicts td", text: "Kept locally"
    screenshot "25-conflict-kept", "#content"

    visit "/projects/#{PROJECT}/mirror"
    click_button "Synchronize now"
    assert_text "Execution queued"
    assert_equal "succeeded", run_worker.status
    assert_match(/edited locally/, issue.reload.subject)
  end

  def test_16_admin_overview
    visit "/admin/mirror?set_filter=1&c[]=project&c[]=modules&c[]=source_wins&c[]=activity&c[]=last_run_at&c[]=last_run_status" \
      "&c[]=last_run_duration&c[]=runs_count&c[]=duration_total&c[]=objects_count&c[]=open_conflicts&t[]=runs_count&t[]=duration_total&group_by=source_url"
    assert_selector "table.mirror-admin-projects tbody tr", minimum: 1
    screenshot "26-admin-overview", "#content", max_height: 620
  end

  # The same Redmine plays a source here: it shares the documents of a project. The log
  # entries stand for two destination runs (fictitious account and address).
  def test_17_mirror_source
    visit "/settings/plugin/redmine_mirror"
    check "settings_source_enabled"
    screenshot "27-source-allowed", "#mirror-source-settings"
    click_button "Apply"
    assert_selector "#flash_notice"
    assert RedmineMirror::Source.enabled?

    handbook = Project.create!(name: "Handbook", identifier: "handbook", is_public: false, enabled_module_names: %w[documents mirror_source])
    category = DocumentCategory.find_by!(name: "Technical documentation")
    documents = ["Architecture", "Operations guide"].map { |title| handbook.documents.create!(title: title, category: category, description: "#{title} of the platform.") }
    visit "/projects/handbook/settings/mirror_source"
    check "mirror-source-share-documents"
    screenshot "28-source-sharing", "#mirror-source-form"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_equal %w[documents], handbook.reload.mirror_source_setting.shared_modules

    reader = User.find_by!(login: "alice")
    log = lambda do |session, minutes, action, **attributes|
      MirrorSourceAccess.create!({ project: handbook, user: reader, session_key: session, remote_ip: "203.0.113.10",
        action: action, created_at: Time.current - minutes.minutes }.merge(attributes))
    end
    refused, synchronized = "1" * 32, "2" * 32
    log.call(refused, 30, "refused", purpose: "references", reason: "not_shared", details: JSON.generate("path" => "/projects/handbook/mirror/source/documents.json"))
    log.call(synchronized, 12, "list", purpose: "synchronization", object_count: 2,
      details: JSON.generate("documents" => documents.map { |document| { "id" => document.id, "title" => document.title, "files" => 1 } }))
    [["architecture.pdf", 482_304], ["operations.pdf", 215_040]].each_with_index do |(filename, bytes), index|
      log.call(synchronized, 11 - index, "download", purpose: "synchronization", object_count: 1, bytes: bytes,
        details: JSON.generate("attachment" => { "id" => 900 + index, "filename" => filename, "document_id" => documents[index].id }))
    end
    visit "/projects/handbook/settings/mirror_source"
    assert_selector "table.mirror-source-sessions tbody tr", count: 2
    screenshot "29-source-log", "#tab-content-mirror_source"
    within("table.mirror-source-sessions tbody tr:first-child") { click_link "Details" }
    assert_selector "table.mirror-source-accesses tbody tr", count: 3
    screenshot "30-source-session", "table.mirror-source-accesses"

    visit "/admin/mirror/source"
    assert_selector "table.mirror-source-sessions tbody tr", count: 2
    screenshot "31-source-activity", "#main", max_height: 900
  end

  # AI proposals (doc/AI.md), against a local stand-in for an OpenAI-compatible API: the
  # destination names its statuses differently, as after a change of workflow.
  def test_18_ai_proposals
    url = start_fake_ai_api
    visit "/admin/mirror/ai"
    check "ai_enabled"
    select "Other OpenAI-compatible API", from: "ai_provider"
    fill_in "ai_url", with: url
    click_button "Save"
    assert_selector "#flash_notice"
    click_button "Test the connection and list the models"
    assert_selector "#flash_notice", text: /models available/
    select "demo-mini — light, recommended", from: "ai_model"
    click_button "Save"
    assert_selector "#mirror-ai-status"
    screenshot "32-ai-settings", "#content", max_height: 900

    # Fewer statuses than the default threshold are used here: offer AI from one.
    MirrorAiConfig.current.update!(min_references: 1)
    FAKE_AI_SYNONYMS.each { |source, local| IssueStatus.find_by(name: source)&.update!(name: local) }
    project.mirror_reference_mappings.where(reference_type: "status").delete_all
    open_module_tab "issue_tracking"
    assert_selector "#mirror-ai-offer-status"
    screenshot "33-ai-offer", "#tab-content-mirror", max_height: 700
    within("#mirror-ai-offer-status") { click_link "Propose with AI" }
    assert_selector "#mirror-ai-status"
    run_worker
    open_module_tab "issue_tracking"
    assert_selector "#mirror-table-status .mirror-ai-suggestion"
    screenshot "34-ai-proposals", "#tab-content-mirror", max_height: 900
  end

  # Guided errors: the statuses of step 18 are still unmapped (proposals are not saved).
  def test_19_guided_errors
    visit "/projects/#{PROJECT}/mirror"
    assert_selector "#mirror-checklist li", text: /Statuses: \d+ without correspondence/
    screenshot "35-checklist", "#mirror-checklist"
    click_button "Run preview"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "partial", run.status, run.error_message
    visit "/projects/#{PROJECT}/mirror/synchronizations/#{run.id}"
    assert_selector "#mirror-error-causes .mirror-guide"
    screenshot "36-guided-errors", "#mirror-run-summary"
  end

  FAKE_AI_SYNONYMS = { "New" => "To do", "In Progress" => "Doing", "Resolved" => "Done", "Feedback" => "Waiting for reply",
                       "Closed" => "Finished", "Rejected" => "Won't do" }.freeze

  private

  # Answers like an OpenAI-compatible API: a model list, and matches from FAKE_AI_SYNONYMS.
  def start_fake_ai_api
    server = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      loop do
        socket = server.accept
        head = +""
        while (line = socket.gets) && line != "\r\n"
          head << line
        end
        body = socket.read(head[/content-length: (\d+)/i, 1].to_i)
        answer = if head.start_with?("GET")
          { "object" => "list", "data" => %w[demo-large demo-mini].map { |id| { "id" => id } } }
        else
          request = JSON.parse(JSON.parse(body)["messages"].last["content"])
          locals = request["destination"].to_h { |local| [local["name"], local["id"]] }
          matches = request["source"].filter_map do |source|
            id = locals[FAKE_AI_SYNONYMS[source["name"]]]
            { "source_id" => source["id"], "local_id" => id, "confidence" => 0.9 } if id
          end
          { "choices" => [{ "message" => { "content" => JSON.generate("matches" => matches) } }], "usage" => { "total_tokens" => 412 } }
        end
        text = JSON.generate(answer)
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
        socket.close
      end
    end
    "http://127.0.0.1:#{server.addr[1]}/v1"
  end

  # Default data plus what an administrator prepares before using Mirror: the
  # destination project, its members and an account for the worker's API key.
  # Rails reloads the test schema when the test starts, hence the default data here.
  def prepare_destination
    FileUtils.mkdir_p(SCREENSHOTS)
    Redmine::DefaultData::Loader.load("en") if Redmine::DefaultData::Loader.no_data?
    admin = User.create!(login: ADMIN_LOGIN, firstname: "Redmine", lastname: "Admin", mail: "#{ADMIN_LOGIN}@example.invalid",
                         admin: true, language: "en", password: ADMIN_PASSWORD, password_confirmation: ADMIN_PASSWORD)
    Token.create!(user: admin, action: "api").update!(value: ENV.fetch("MIRROR_DESTINATION_API_KEY"))
    project = Project.create!(name: "Mirror Demo", identifier: PROJECT, is_public: false,
                              enabled_module_names: %w[issue_tracking time_tracking])
    project.trackers = Tracker.all
    manager = Role.find_by!(name: "Manager")
    [%w[alice Alice Mirror], %w[mirror-archive Mirror Archive]].each do |login, firstname, lastname|
      user = User.create!(login: login, firstname: firstname, lastname: lastname, mail: "#{login}@example.invalid",
                          language: "en", password: ADMIN_PASSWORD, password_confirmation: ADMIN_PASSWORD)
      Member.create!(project: project, user: user, roles: [manager])
    end
  end

  def project
    Project.find_by!(identifier: PROJECT)
  end

  def open_module_tab(key)
    visit "/projects/#{PROJECT}/settings/mirror?mirror_tab=#{key}"
    assert_selector "#mirror-settings-subtabs a.selected[href*='mirror_tab=#{key}']"
  end

  # Selects the local reference named like the remote one, unless overridden.
  def map_by_name(table, overrides = {})
    within("#mirror-table-#{table}") do
      all("tbody tr").each do |row|
        name = row.find("td", match: :first).text.sub(/ \(#\d+\)\z/, "")
        field = row.find("select")
        choice = overrides.fetch(name) { field.all("option").map(&:text).find { |text| text.sub(/ \(#\d+\)(?: .*)?\z/, "") == name } }
        assert choice, "No local #{table} named #{name}"
        field.select(choice)
      end
    end
  end

  # Does what `rake redmine_mirror:tick` does in the worker process, then returns
  # the latest run.
  def run_worker
    RedmineMirror::Synchronization.tick
    project.mirror_sync_runs.order(:id).last
  end

  # Redmine's helper compares the current path without waiting on some versions.
  def log_user(login, password)
    visit "/my/page"
    assert_current_path "/login", ignore_query: true
    within("#login-form form") do
      fill_in "username", with: login
      fill_in "password", with: password
      find('input[name="login"]').click
    end
    assert_current_path "/my/page", ignore_query: true
  end

  # Captures one element of the page at a fixed desktop width. Redmine's top bar is
  # hidden unless it is the subject, and the viewport is stretched to the whole page.
  def screenshot(name, target, width: 1280, max_height: nil)
    browser = page.driver.browser
    element = target.is_a?(String) ? find(target) : target
    page.execute_script(<<~JS, element)
      const chrome = ["top-menu", "header", "footer"].map(id => document.getElementById(id)).filter(Boolean);
      chrome.forEach(block => { if (!block.contains(arguments[0])) block.style.display = "none"; });
    JS
    metrics = ->(height) { browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false) }
    metrics.call(900)
    page.execute_script("window.scrollTo(0, 0)")
    metrics.call([page.evaluate_script("document.documentElement.scrollHeight").to_i, 900].max)
    # Redmine's content area keeps a minimum height: stop below its last visible block.
    box = page.evaluate_script(<<~JS, element)
      (() => {
        const box = arguments[0].getBoundingClientRect().toJSON();
        const bottoms = [...arguments[0].children].map(child => child.getBoundingClientRect())
          .filter(rect => rect.width > 0 && rect.height > 0).map(rect => rect.bottom);
        if (bottoms.length) box.height = Math.min(box.height, Math.max(...bottoms) + 8 - box.top);
        return box;
      })()
    JS
    margin = 4
    height = box["height"] + 2 * margin
    clip = {
      x: [box["left"] - margin, 0].max, y: [box["top"] - margin, 0].max,
      width: box["width"] + 2 * margin, height: max_height ? [height, max_height].min : height, scale: 1
    }
    data = browser.execute_cdp("Page.captureScreenshot", format: "png", clip: clip, fromSurface: true)["data"]
    File.binwrite(File.join(SCREENSHOTS, "#{name}.png"), Base64.decode64(data))
  ensure
    browser&.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
