# frozen_string_literal: true
# File: redmine_mirror/test/documentation/migration_4_to_5_test.rb
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
# Walk through doc/MIGRATION_4_TO_5.md in a browser and regenerate its screenshots.
# Run it with test/documentation/migration_run.sh: the source is a real Redmine 4.2 in
# its own container, this test is the Redmine 5 destination and drives both browsers.

require File.expand_path("test/application_system_test_case", Dir.pwd)
require "net/http"
require_relative "documentation_helpers"

class MirrorMigrationDocumentationTest < ApplicationSystemTestCase
  include MirrorDocumentationHelpers

  # Steps follow the document: each one starts where the previous one left both Redmines.
  i_suck_and_my_tests_are_order_dependent!
  self.use_transactional_tests = false
  self.fixture_table_names = []

  SCREENSHOTS = File.join(ENV.fetch("MIRROR_DOC_SCREENSHOTS") { Rails.root.join("tmp/redmine_mirror/screenshots").to_s }, "migration")
  SOURCE_URL = ENV.fetch("MIRROR_SOURCE_URL")
  SOURCE_ADMIN_PASSWORD = ENV.fetch("MIRROR_SOURCE_ADMIN_PASSWORD")
  # The source administrator's key, set by the disposable environment (api_token.rb):
  # only used to add the service account to the project, as an administrator would.
  SOURCE_ADMIN_KEY = "1" * 40
  PROJECT = "mirror-demo"
  READER_LOGIN = "mirror-reader"
  READER_PASSWORD = "Mirror-reader-123!"
  ADMIN_LOGIN = "mirror-doc-admin"
  ADMIN_PASSWORD = "Mirror-doc-123!"
  MODULES = %w[issue_categories project_versions issue_tracking time_tracking issue_journals issue_attachments].freeze
  # Everything Mirror reads on the source, nothing it could change.
  READER_PERMISSIONS = %w[view_issues view_private_notes view_time_entries view_issue_watchers view_wiki_pages
                          view_wiki_edits view_files view_documents view_members].freeze

  setup do
    prepare_destination unless self.class.instance_variable_get(:@prepared)
    self.class.instance_variable_set(:@prepared, true)
  end

  # Part 1: the Redmine 4.2 source.

  def test_01_source_version
    source_login("admin", SOURCE_ADMIN_PASSWORD)
    visit "#{SOURCE_URL}/admin/info"
    assert_text "4.2"
    screenshot "01-source-version", "#content", max_height: 360
  end

  def test_02_source_rest_api
    source_login("admin", SOURCE_ADMIN_PASSWORD)
    visit "#{SOURCE_URL}/settings?tab=api"
    check "settings_rest_api_enabled"
    screenshot "02-source-rest-api", "#tab-content-api"
    within("#tab-content-api") { click_button "Save" }
    assert_selector "#flash_notice"
  end

  def test_03_source_role
    source_login("admin", SOURCE_ADMIN_PASSWORD)
    visit "#{SOURCE_URL}/roles/new"
    fill_in "role_name", with: "Mirror reader"
    # A read-only service account is never an assignee.
    uncheck "role_assignable" if page.has_field?("role_assignable", checked: true, wait: 0)
    select "All issues", from: "role_issues_visibility"
    select "All time entries", from: "role_time_entries_visibility" if page.has_select?("role_time_entries_visibility", wait: 0)
    # Start from no permission: Redmine checks a few by default on a new role.
    all("input[name='role[permissions][]'][type=checkbox]").each { |box| box.uncheck if box.checked? }
    READER_PERMISSIONS.each do |permission|
      box = first("input[name='role[permissions][]'][value='#{permission}']", minimum: 0)
      box&.check
    end
    screenshot "03-source-role", "#content", max_height: 900
    click_button "Create"
    assert_selector "#flash_notice"
  end

  def test_04_source_service_account
    source_login("admin", SOURCE_ADMIN_PASSWORD)
    visit "#{SOURCE_URL}/users/new"
    fill_in "user_login", with: READER_LOGIN
    fill_in "user_firstname", with: "Mirror"
    fill_in "user_lastname", with: "Reader"
    fill_in "user_mail", with: "#{READER_LOGIN}@example.invalid"
    fill_in "user_password", with: READER_PASSWORD
    fill_in "user_password_confirmation", with: READER_PASSWORD
    screenshot "04-source-service-account", "#content", max_height: 620
    click_button "Create"
    assert_selector "#flash_notice"
    # Membership through the source API, as the project's members tab would add it.
    user = source_api(Net::HTTP::Get, "users.json?name=#{READER_LOGIN}").fetch("users").first
    role = source_api(Net::HTTP::Get, "roles.json").fetch("roles").find { |entry| entry["name"] == "Mirror reader" }
    source_api(Net::HTTP::Post, "projects/#{PROJECT}/memberships.json", "membership" => { "user_id" => user.fetch("id"), "role_ids" => [role.fetch("id")] })
    visit "#{SOURCE_URL}/projects/#{PROJECT}/settings/members"
    assert_text "Mirror Reader"
    screenshot "05-source-membership", "#tab-content-members"
  end

  def test_05_source_api_key
    Capybara.using_session(:reader) do
      source_login(READER_LOGIN, READER_PASSWORD)
      visit "#{SOURCE_URL}/my/account"
      within("#sidebar") { click_link "Show" }
      key = find("#api-access-key").text.strip
      assert_match(/\A\h{40}\z/, key)
      self.class.instance_variable_set(:@reader_key, key)
      screenshot "06-source-api-key", "#sidebar"
    end
  end

  # Part 2: the Redmine 5 destination.

  def test_06_destination_plugin
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/admin/info"
    assert_text "5."
    visit "/admin/plugins"
    assert_selector "tr#plugin-redmine_mirror"
    screenshot "07-destination-plugin", "#content", max_height: 420
  end

  def test_07_destination_settings
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/settings?tab=api"
    check "settings_rest_api_enabled"
    within("#tab-content-api") { click_button "Save" }
    assert_selector "#flash_notice"
    visit "/settings/plugin/redmine_mirror"
    fill_in "settings_allowed_source_urls", with: SOURCE_URL
    screenshot "08-allowed-source", "#content", max_height: 420
    click_button "Apply"
    assert_selector "#flash_notice"
  end

  def test_08_destination_project
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/projects/new"
    fill_in "project_name", with: "Mirror Demo"
    fill_in "project_identifier", with: PROJECT
    %w[issue_tracking time_tracking mirror].each { |name| check "project_enabled_module_names_#{name}" }
    screenshot "09-destination-project", "#content", max_height: 900
    click_button "Create"
    assert_selector "#flash_notice"
    # The project's members, as the organization sets them on the new Redmine.
    manager = Role.find_by!(name: "Manager")
    project.trackers = Tracker.all
    %w[alice mirror-archive].each { |login| Member.create!(project: project, user: User.find_by!(login: login), roles: [manager]) }
  end

  # Part 3: migrate the project.

  def test_09_connect
    # Redmine's system tests clear the settings between steps: restore what step 7 saved.
    Setting.rest_api_enabled = "1"
    Setting.plugin_redmine_mirror = Setting.plugin_redmine_mirror.to_h.merge("allowed_source_urls" => SOURCE_URL)
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/projects/#{PROJECT}/settings/mirror"
    select SOURCE_URL, from: "connection_source_url"
    fill_in "connection_source_project_id", with: PROJECT
    fill_in "connection_api_key", with: self.class.instance_variable_get(:@reader_key)
    # Redmine 4.2 formats texts in Textile: say so rather than relying on detection.
    select "Textile", from: "connection_source_text_format"
    MODULES.each { |key| find("input[name='connection[modules][]'][value='#{key}']").check }
    screenshot "10-connect", "#tab-content-mirror"
    click_button "Save"
    assert_selector "#flash_notice"
    # What the worker does next (rake redmine_mirror:tick).
    RedmineMirror::Synchronization.refresh_catalogs
    visit current_url
    assert_selector "#mirror-settings-subtabs .mirror-badge"
  end

  def test_10_map
    Setting.rest_api_enabled = "1"
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    open_module_tab "users"
    map_by_name "user", "Redmine Admin" => "Anonymize"
    select "Mirror Archive", from: "anonymous-time-user"
    screenshot "11-map-users", "#tab-content-mirror"
    click_button "Save"
    assert_selector "#flash_notice"
    open_module_tab "issue_tracking"
    %w[tracker status priority].each { |table| map_by_name table }
    screenshot "12-map-issues", "#tab-content-mirror"
    click_button "Save"
    assert_selector "#flash_notice"
    open_module_tab "time_tracking"
    map_by_name "activity"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_no_selector "#mirror-settings-subtabs .mirror-badge"
  end

  def test_11_preview
    Setting.rest_api_enabled = "1"
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/projects/#{PROJECT}/mirror"
    click_button "Run preview"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    assert project.issues.none?
    visit current_path
    screenshot "13-preview", "#content", max_height: 700
  end

  def test_12_import
    Setting.rest_api_enabled = "1"
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/projects/#{PROJECT}/mirror"
    click_button "Synchronize now"
    assert_text "Execution queued"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    assert_equal source_issue_count, project.issues.count
    visit current_path
    screenshot "14-import", "#content", max_height: 700
    issue = project.issues.order(:id).first
    visit "/issues/#{issue.id}"
    assert_selector "#mirror-issue-origin"
    screenshot "15-imported-issue", "#content", max_height: 900
  end

  def test_13_check
    Setting.rest_api_enabled = "1"
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/admin/mirror?set_filter=1&c[]=project&c[]=source_url&c[]=last_run_at&c[]=last_run_status&c[]=runs_count&c[]=objects_count&c[]=open_conflicts&c[]=pending_links"
    assert_selector "table.mirror-admin-projects tbody tr", count: 1
    screenshot "16-check", "#content", max_height: 460
  end

  # Part 4: keep in sync until the cutover.

  def test_14_keep_in_sync
    Setting.rest_api_enabled = "1"
    # Work goes on in Redmine 4.2: a note is added there.
    issue_id = source_api(Net::HTTP::Get, "issues.json?project_id=#{PROJECT}&status_id=*&sort=id&limit=1").fetch("issues").first.fetch("id")
    source_api(Net::HTTP::Put, "issues/#{issue_id}.json", "issue" => { "notes" => "Added in Redmine 4.2 after the first import." })
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/projects/#{PROJECT}/mirror"
    click_button "Synchronize now"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    assert_equal 1, run.log_events.count { |event| event["module"] == "issue_journals" && event["action"] == "create" }
    visit "/projects/#{PROJECT}/mirror/synchronizations/#{run.id}?action_filter=create"
    screenshot "17-resync", "#mirror-log"
    visit "/projects/#{PROJECT}/settings/mirror?mirror_tab=schedule"
    check "schedule-enabled"
    select "Every 15 minutes", from: "schedule-interval"
    check "schedule-source-wins"
    screenshot "18-schedule", "form[action$='/mirror/schedule']"
    click_button "Save"
    assert_selector "#flash_notice"
  end

  def test_15_cutover
    Setting.rest_api_enabled = "1"
    # Freeze the source project: closed, it stays readable but nobody can change it.
    source_login("admin", SOURCE_ADMIN_PASSWORD)
    visit "#{SOURCE_URL}/projects/#{PROJECT}"
    # Redmine 4.2 keeps Close in the "..." menu of the project overview.
    find("#content .contextual .drdn-trigger").click if page.has_css?("#content .contextual .drdn-trigger", wait: 0)
    accept_confirm { click_link "Close" }
    assert_text "This project is closed and read-only."
    screenshot "19-source-closed", "#content", max_height: 300
    # Last synchronization, then the schedule is stopped.
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
    visit "/projects/#{PROJECT}/mirror"
    click_button "Synchronize now"
    run = run_worker
    assert_equal "succeeded", run.status, run.error_message
    visit "/projects/#{PROJECT}/settings/mirror?mirror_tab=schedule"
    uncheck "schedule-enabled"
    click_button "Save"
    assert_selector "#flash_notice"
    visit "/projects/#{PROJECT}/mirror"
    screenshot "20-final", "#content", max_height: 620
  end

  private

  # Default data, the destination administrator with the worker's API key, and the
  # accounts the organization has already created on the new Redmine.
  def prepare_destination
    FileUtils.mkdir_p(SCREENSHOTS)
    Redmine::DefaultData::Loader.load("en") if Redmine::DefaultData::Loader.no_data?
    admin = User.create!(login: ADMIN_LOGIN, firstname: "Redmine", lastname: "Admin", mail: "#{ADMIN_LOGIN}@example.invalid",
                         admin: true, language: "en", password: ADMIN_PASSWORD, password_confirmation: ADMIN_PASSWORD)
    Token.create!(user: admin, action: "api").update!(value: ENV.fetch("MIRROR_DESTINATION_API_KEY"))
    [%w[alice Alice Mirror], %w[mirror-archive Mirror Archive]].each do |login, firstname, lastname|
      User.create!(login: login, firstname: firstname, lastname: lastname, mail: "#{login}@example.invalid",
                   language: "en", password: ADMIN_PASSWORD, password_confirmation: ADMIN_PASSWORD)
    end
  end

  def project
    Project.find_by!(identifier: PROJECT)
  end

  def open_module_tab(key)
    visit "/projects/#{PROJECT}/settings/mirror?mirror_tab=#{key}"
    assert_selector "#mirror-settings-subtabs a.selected[href*='mirror_tab=#{key}']"
  end

  def run_worker
    RedmineMirror::Synchronization.tick
    project.mirror_sync_runs.order(:id).last
  end

  # Logs in on the source Redmine, in the current browser session.
  def source_login(login, password)
    visit "#{SOURCE_URL}/login"
    return if page.has_css?("#loggedas", wait: 0) && page.has_text?(login, wait: 0)
    within("#login-form form") do
      fill_in "username", with: login
      fill_in "password", with: password
      find('input[name="login"]').click
    end
    assert_selector "#loggedas"
  end

  def source_issue_count
    source_api(Net::HTTP::Get, "issues.json?project_id=#{PROJECT}&status_id=*&subproject_id=!*&limit=1").fetch("total_count")
  end

  # The source REST API as its administrator (disposable demo data only).
  def source_api(verb, path, body = nil)
    uri = URI.join("#{SOURCE_URL}/", path)
    request = verb.new(uri)
    request["X-Redmine-API-Key"] = SOURCE_ADMIN_KEY
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    raise "Source #{verb.name.demodulize.upcase} #{path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end
end
