# frozen_string_literal: true
# File: redmine_mirror/test/documentation/mirror_copy_test.rb
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
# Walk through doc/MIRROR_COPY.md in a browser and regenerate its screenshots.
# Run it with test/documentation/run.sh, after the configuration guide: it reuses the
# seeded source Redmine and prepares its own destination project.

require File.expand_path("test/application_system_test_case", Dir.pwd)
require "net/http"
require_relative "documentation_helpers"

class MirrorCopyDocumentationTest < ApplicationSystemTestCase
  include MirrorDocumentationHelpers

  # Steps follow the document: each one starts where the previous one left the database.
  i_suck_and_my_tests_are_order_dependent!
  self.use_transactional_tests = false
  self.fixture_table_names = []

  SCREENSHOTS = File.join(ENV.fetch("MIRROR_DOC_SCREENSHOTS") { Rails.root.join("tmp/redmine_mirror/screenshots").to_s }, "mirror-copy")
  SOURCE_URL = ENV.fetch("MIRROR_SOURCE_URL")
  SOURCE_API_KEY = ENV.fetch("MIRROR_SOURCE_API_KEY")
  SOURCE_PROJECT = "mirror-demo"
  PROJECT = "mirror-copy"
  ADMIN_LOGIN = "mirror-doc-admin"
  ADMIN_PASSWORD = "Mirror-doc-123!"
  MODULES = %w[issue_categories project_versions issue_tracking time_tracking issue_journals].freeze

  setup do
    prepare_destination unless self.class.instance_variable_get(:@prepared)
    self.class.instance_variable_set(:@prepared, true)
    Setting.rest_api_enabled = "1"
    log_user(ADMIN_LOGIN, ADMIN_PASSWORD)
  end

  # A project already configured and imported (doc/CONFIGURATION.md) is the starting point.
  def test_01_starting_point
    configure_project
    run = synchronize
    reasons = run.log_events.select { |event| event["action"] == "error" }.map { |event| event["reason"] }.uniq.first(5)
    assert_equal "succeeded", run.status, "#{run.error_message} #{reasons.inspect}"
    assert_equal source_issue_count, project.issues.count
    visit "/projects/#{PROJECT}/mirror"
    screenshot "01-starting-point", "#content", max_height: 620
  end

  def test_02_mirror_mode
    visit "/projects/#{PROJECT}/settings/mirror?mirror_tab=schedule"
    check "schedule-enabled"
    select "Every 15 minutes", from: "schedule-interval"
    check "schedule-source-wins"
    screenshot "02-mirror-mode", "form[action$='/mirror/schedule']"
    click_button "Save"
    assert_selector "#flash_notice"
    assert project.mirror_project_setting.reload.source_wins?
  end

  def test_03_local_edit_is_overwritten
    issue = first_issue
    issue.init_journal(User.find_by!(login: "alice"))
    issue.update!(subject: "#{issue.subject} (edited locally)")
    run = synchronize
    assert_equal "succeeded", run.status
    refute_match(/edited locally/, issue.reload.subject)
    visit "/projects/#{PROJECT}/mirror/synchronizations/#{run.id}?action_filter=update"
    screenshot "03-local-edit-overwritten", "#mirror-log"
  end

  def test_04_local_deletion_is_recreated
    first_issue.destroy
    run = synchronize
    assert_equal source_issue_count, project.issues.count
    visit "/projects/#{PROJECT}/mirror/synchronizations/#{run.id}?action_filter=create"
    screenshot "04-local-deletion-recreated", "#mirror-log"
  end

  # Five issues are created on the source, imported, then one is deleted there.
  def test_05_source_deletion
    ids = (1..5).map { |number| create_source_issue("Temporary issue #{number}") }
    self.class.instance_variable_set(:@temporary, ids)
    synchronize
    delete_source_issue(ids.first)
    preview = synchronize(apply: false)
    assert_equal 1, preview.log_events.count { |event| event["action"] == "delete" }
    visit "/projects/#{PROJECT}/mirror/synchronizations/#{preview.id}?action_filter=delete"
    screenshot "05-preview-deletion", "#mirror-log"
    run = synchronize
    assert_equal 1, run.log_events.count { |event| event["action"] == "delete" }
    assert_equal source_issue_count, project.issues.count
  end

  # Beyond the limit (10% of a module, at least 2), deletions wait for a confirmation.
  def test_06_deletion_limit
    self.class.instance_variable_get(:@temporary).drop(1).each { |id| delete_source_issue(id) }
    count = project.issues.count
    blocked = synchronize
    assert_equal "partial", blocked.status
    assert_equal count, project.issues.count
    visit "/projects/#{PROJECT}/mirror"
    assert_selector "#mirror-confirm-deletions"
    screenshot "06-deletions-to-confirm", "#mirror-actions"
    accept_confirm { click_button "Synchronize and confirm the 4 deletions" }
    assert_text "Execution queued"
    run = run_worker
    assert_equal "succeeded", run.status
    assert_equal source_issue_count, project.issues.count
    visit "/projects/#{PROJECT}/mirror/synchronizations/#{run.id}?action_filter=delete"
    screenshot "07-deletions-confirmed", "#mirror-log"
  end

  def test_07_admin_overview
    visit "/admin/mirror?set_filter=1&f[]=source_wins&op[source_wins]==&v[source_wins][]=1" \
          "&c[]=project&c[]=source_wins&c[]=auto_sync_enabled&c[]=next_sync_at&c[]=last_run_at&c[]=last_run_status&c[]=runs_count&c[]=open_conflicts"
    assert_selector "table.mirror-admin-projects tbody tr", count: 1
    screenshot "08-admin-overview", "#content", max_height: 460
  end

  private

  # Default data, an administrator with the worker's API key, and the destination
  # project with its members. Idempotent: the configuration guide may have run first.
  def prepare_destination
    FileUtils.mkdir_p(SCREENSHOTS)
    Redmine::DefaultData::Loader.load("en") if Redmine::DefaultData::Loader.no_data?
    admin = User.find_by(login: ADMIN_LOGIN) || User.create!(login: ADMIN_LOGIN, firstname: "Redmine", lastname: "Admin",
      mail: "#{ADMIN_LOGIN}@example.invalid", admin: true, language: "en", password: ADMIN_PASSWORD, password_confirmation: ADMIN_PASSWORD)
    Token.find_or_create_by!(user: admin, action: "api").update!(value: ENV.fetch("MIRROR_DESTINATION_API_KEY"))
    return if Project.exists?(identifier: PROJECT)
    project = Project.create!(name: "Mirror Copy", identifier: PROJECT, is_public: false,
                              enabled_module_names: %w[mirror issue_tracking time_tracking])
    project.trackers = Tracker.all
    manager = Role.find_by!(name: "Manager")
    [%w[alice Alice Mirror], %w[mirror-archive Mirror Archive]].each do |login, firstname, lastname|
      user = User.find_by(login: login) || User.create!(login: login, firstname: firstname, lastname: lastname,
        mail: "#{login}@example.invalid", language: "en", password: ADMIN_PASSWORD, password_confirmation: ADMIN_PASSWORD)
      Member.create!(project: project, user: user, roles: [manager])
    end
  end

  # What doc/CONFIGURATION.md does in the browser, done directly: connection, references
  # and mappings by name, the source administrator anonymized.
  def configure_project
    setting = MirrorProjectSetting.new(project: project, source_url: SOURCE_URL, source_project_id: source_project_id)
    setting.api_key = SOURCE_API_KEY
    setting.selected_modules = MODULES
    setting.module_options = { "users" => { "anonymous_user_id" => User.find_by!(login: "mirror-archive").id } }
    setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: source_project_id, adapters: setting.adapters).fetch
    setting.save!
    locals = { "tracker" => Tracker, "status" => IssueStatus, "priority" => IssuePriority, "activity" => TimeEntryActivity }
    catalog = setting.source_catalog
    catalog.slice(*locals.keys, "user").each do |kind, references|
      # Every source reference with a local namesake, as the forms preselect them.
      references.each do |id, name|
        if kind == "user"
          alice = User.find_by!(login: "alice")
          attributes = name == alice.name ? { mode: "existing", destination_id: alice.id } : { mode: "anonymous" }
        else
          # The configuration guide renames some local references to show the AI
          # proposals: both sides loaded the same default data, so the IDs match.
          local = locals.fetch(kind).find_by(name: name) || locals.fetch(kind).find_by(id: id)
          next unless local
          attributes = { mode: "existing", destination_id: local.id }
        end
        project.mirror_reference_mappings.create!(attributes.merge(reference_type: kind, source_id: id))
      end
    end
  end

  def project
    Project.find_by!(identifier: PROJECT)
  end

  def first_issue
    project.issues.order(:id).first
  end

  # Queues a run as the Mirror page does and processes it as the worker does.
  def synchronize(apply: true)
    RedmineMirror::Synchronization.enqueue(project.mirror_project_setting, apply: apply, trigger: "manual", user: User.find_by!(login: ADMIN_LOGIN))
    run_worker
  end

  def run_worker
    RedmineMirror::Synchronization.tick
    project.mirror_sync_runs.order(:id).last
  end

  def source_project_id
    @source_project_id ||= source_request(Net::HTTP::Get, "projects/#{SOURCE_PROJECT}.json").fetch("project").fetch("id")
  end

  def source_issue_count
    source_request(Net::HTTP::Get, "issues.json?project_id=#{source_project_id}&status_id=*&subproject_id=!*&limit=1").fetch("total_count")
  end

  def create_source_issue(subject)
    source_request(Net::HTTP::Post, "issues.json", "issue" => { "project_id" => source_project_id, "subject" => subject, "tracker_id" => 1 })
      .fetch("issue").fetch("id")
  end

  def delete_source_issue(id)
    source_request(Net::HTTP::Delete, "issues/#{id}.json")
  end

  # The source Redmine's REST API with its administrator key (seeded demo data only).
  def source_request(verb, path, body = nil)
    uri = URI.join("#{SOURCE_URL}/", path)
    request = verb.new(uri)
    request["X-Redmine-API-Key"] = SOURCE_API_KEY
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    raise "Source #{verb.name.demodulize.upcase} #{path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end
end
