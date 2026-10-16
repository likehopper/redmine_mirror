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

require File.expand_path("../../../../test/application_system_test_case", __dir__)

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

  def test_03_roles_get_mirror_permissions
    role = Role.find_by!(name: "Manager")
    visit "/roles/#{role.id}/edit"
    fieldset = find("#role_permissions_view_mirror").ancestor("fieldset")
    fieldset.check("role_permissions_view_mirror")
    fieldset.check("role_permissions_manage_mirror")
    screenshot "03-role-permissions", fieldset
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_04_project_enables_the_module
    visit "/projects/#{PROJECT}/settings/info"
    check "project_enabled_module_names_mirror"
    screenshot "04-project-modules", "#project_modules"
    within("#tab-content-info") { click_button "Save" }
    assert_selector "#flash_notice"
    assert_selector "#main-menu a.mirror"
    screenshot "05-project-menu", "#main-menu"
  end

  def test_05_connection
    visit "/projects/#{PROJECT}"
    within("#main-menu") { click_link "Mirror" }
    assert_current_path "/projects/#{PROJECT}/mirror/settings"
    fill_in "connection_source_url", with: SOURCE_URL
    fill_in "connection_source_project_id", with: source_project_id.to_s
    fill_in "connection_api_key", with: SOURCE_API_KEY
    MODULES.each { |key| find("input[name='connection[modules][]'][value='#{key}']").check }
    screenshot "06-connection", "#content"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_empty MODULES - project.mirror_project_setting.selected_modules
    assert_no_text SOURCE_API_KEY
  end

  def test_06_user_mappings
    open_module_tab "users"
    map_by_name "user", "Redmine Admin" => "Anonymize"
    select "Mirror Archive", from: "anonymous-time-user"
    screenshot "07-users", "#content"
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_07_issue_and_time_mappings
    open_module_tab "issue_tracking"
    %w[tracker status priority].each { |table| map_by_name table }
    screenshot "08-issues", "#content"
    click_button "Save"
    assert_selector "#flash_notice"

    open_module_tab "time_tracking"
    map_by_name "activity"
    screenshot "09-time-tracking", "#content"
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_08_relation_policy
    open_module_tab "issue_relations"
    select "Add a private note", from: "missing_target"
    screenshot "10-relations-policy", "#content"
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_09_preview
    visit "/projects/#{PROJECT}/mirror/settings?tab=synchronization"
    screenshot "11-synchronization", "#content"
    click_button "Run preview"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    assert project.issues.none?
    visit current_path
    screenshot "12-preview-log", "#content", max_height: 760
  end

  def test_10_import
    visit "/projects/#{PROJECT}/mirror/settings?tab=synchronization"
    click_button "Synchronize now"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    assert_equal 12, project.issues.count
    visit current_path
    screenshot "13-import-log", "#content", max_height: 760
    # README illustration.
    screenshot "home", "#content", max_height: 520
    visit "/projects/#{PROJECT}/mirror/settings?tab=synchronization"
    screenshot "14-synchronization-done", "#content"
  end

  def test_11_imported_data
    visit "/projects/#{PROJECT}/mirror/settings?tab=objects"
    assert_selector "table.list tbody tr"
    screenshot "15-object-mappings", "#content", max_height: 760
    issue = project.issues.order(:id).first
    visit "/issues/#{issue.id}"
    assert_selector "#mirror-issue-origin"
    screenshot "16-imported-issue", "#content", max_height: 900
    visit "/projects/#{PROJECT}/mirror/settings?tab=issue_relations"
    assert_selector "#mirror-pending-relations tbody tr"
    screenshot "17-pending-relations", "#content"
  end

  def test_12_schedule
    visit "/projects/#{PROJECT}/mirror/settings?tab=synchronization"
    check "schedule-enabled"
    select "Every 60 minutes", from: "schedule-interval"
    click_button "Save"
    assert_selector "#flash_notice"
    assert project.mirror_project_setting.auto_sync_enabled?
    screenshot "18-schedule", find("#schedule-enabled").ancestor("form")
  end

  def test_13_history
    visit "/projects/#{PROJECT}/mirror/settings?tab=history"
    assert_selector "#mirror-history tbody tr", count: 2
    screenshot "19-history", "#content"
  end

  def test_14_conflict
    # A destination user edits an imported issue: Mirror must not overwrite it.
    issue = project.issues.order(:id).first
    issue.init_journal(User.find_by!(login: "alice"))
    issue.update!(subject: "#{issue.subject} (edited locally)")
    visit "/projects/#{PROJECT}/mirror/settings?tab=synchronization"
    click_button "Synchronize now"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "failed", run.status
    visit current_path
    screenshot "20-conflict-log", "#content", max_height: 460
    visit "/projects/#{PROJECT}/mirror/settings?tab=conflicts"
    assert_selector "#mirror-conflicts tbody tr", count: 1
    screenshot "21-conflicts", "#content"
    accept_confirm { click_button "Keep local object" }
    assert_selector "#flash_notice"
    assert_selector "#mirror-conflicts td", text: "Kept locally"
    screenshot "22-conflict-kept", "#content"

    visit "/projects/#{PROJECT}/mirror/settings?tab=synchronization"
    click_button "Synchronize now"
    assert_text "Execution queued"
    assert_equal "succeeded", run_worker.status
    assert_match(/edited locally/, issue.reload.subject)
  end

  private

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

  def source_project_id
    RedmineMirror::Client.new(url: SOURCE_URL, api_key: SOURCE_API_KEY, allow_http: true)
                         .get("projects/#{PROJECT}.json").fetch("project").fetch("id")
  end

  def open_module_tab(key)
    visit "/projects/#{PROJECT}/mirror/settings?tab=#{key}"
    assert_selector "#mirror-settings-subtabs a.selected[href*='tab=#{key}']"
  end

  # Selects the local reference named like the remote one, unless overridden.
  def map_by_name(table, overrides = {})
    within("#mirror-table-#{table}") do
      all("tbody tr").each do |row|
        name = row.find("td", match: :first).text.sub(/ \(#\d+\)\z/, "")
        field = row.find("select")
        choice = overrides.fetch(name) { field.all("option").map(&:text).find { |text| text.sub(/ \(#\d+\)\z/, "") == name } }
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
