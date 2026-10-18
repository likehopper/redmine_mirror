# frozen_string_literal: true
# File: redmine_mirror/test/environment/synchronization_smoke.rb
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
# Exercise Mirror behavior against the disposable Redmine environment.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
require "selenium-webdriver"
# The worker writes from another process; polling must bypass Rails' query cache.
ActiveRecord::Base.connection.disable_query_cache!
manual = Project.find_by!(identifier: "mirror-demo")
original = manual.mirror_project_setting
project = Project.create!(name: "Synchronization smoke", identifier: "sync-smoke-#{SecureRandom.hex(4)}",
  enabled_module_names: %w[mirror issue_tracking time_tracking])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: original.source_project_id)
# A fixed selection keeps the expected counts independent of the manual project's modules.
setting.selected_modules = %w[issue_categories project_versions issue_tracking time_tracking]
setting.api_key = original.api_key
setting.source_catalog = original.source_catalog
setting.module_options = original.module_options
setting.save!
manual.mirror_reference_mappings.each do |row|
  project.mirror_reference_mappings.create!(reference_type: row.reference_type, source_id: row.source_id,
    destination_id: row.destination_id, mode: row.mode)
end
options = Selenium::WebDriver::Chrome::Options.new
%w[--headless --no-sandbox --disable-dev-shm-usage].each { |flag| options.add_argument(flag) }
options.binary = "/usr/bin/chromium"
driver = Selenium::WebDriver.for(:chrome, options: options, service: Selenium::WebDriver::Chrome::Service.new(path: "/usr/bin/chromedriver"))
wait = Selenium::WebDriver::Wait.new(timeout: 100)
begin
  wait.until do
    driver.navigate.to("http://gateway:3102/login")
    driver.find_elements(id: "username").any?
  end
  driver.find_element(id: "username").send_keys("admin")
  driver.find_element(id: "password").send_keys("Mirror-test-2026!")
  driver.find_element(name: "login").click
  wait.until { driver.find_elements(id: "loggedas").any? }
  page_url = "http://gateway:3102/projects/#{project.identifier}/mirror"
  driver.navigate.to(page_url)
  driver.find_element(css: 'form[action$="/synchronizations"] input[value="preview"]').find_element(xpath: "..").find_element(css: '[type="submit"]').click
  wait.until do
    run = project.mirror_sync_runs.order(:id).last
    abort "Preview failed: #{run.error_message}" if run&.status == "failed"
    run&.status == "succeeded"
  end
  preview = project.mirror_sync_runs.last
  abort "Preview wrote data" unless project.issues.count.zero? && project.time_entries.count.zero?
  abort "Missing preview log" unless preview.log_events.size == 27
  abort "Incorrect progress" unless preview.total_records == 27 && preview.processed_records == 27 && preview.progress_percentage == 100
  abort "Missing module totals" unless preview.module_counts["issue_tracking"] == 12 && preview.module_counts["time_tracking"] == 13
  driver.navigate.to(page_url)
  driver.find_element(css: 'form[action$="/synchronizations"] input[value="apply"]').find_element(xpath: "..").find_element(css: '[type="submit"]').click
  wait.until do
    run = project.mirror_sync_runs.where(apply: true).order(:id).last
    abort "Manual import failed: #{run.error_message}" if run&.status == "failed"
    run&.status == "succeeded"
  end
  abort "Incomplete manual import" unless project.issues.count == 12 && project.time_entries.count == 13
  imported = project.mirror_sync_runs.where(apply: true).order(:id).last
  abort "Missing local IDs in logs" unless imported.log_events.all? { |event| event["destination_id"].present? }
  abort "Missing project object mappings" unless MirrorMapping.where(project_id: project.id).count == 27
  driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/mirror?tab=objects")
  abort "Missing remote object links" unless driver.find_elements(css: 'a[href^="http://localhost:3101/issues/"]').size == 12
  abort "Missing local object links" unless driver.find_elements(css: 'a[href^="/issues/"]').size == 12
  driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/settings/mirror?mirror_tab=schedule")
  driver.find_element(id: "schedule-enabled").click
  Selenium::WebDriver::Support::Select.new(driver.find_element(id: "schedule-interval")).select_by(:value, "15")
  driver.find_element(css: "#tab-content-mirror [name=commit]").click
  # The form posts asynchronously from this process's point of view: wait for the save.
  Selenium::WebDriver::Wait.new(timeout: 20).until { setting.reload.auto_sync_enabled? } rescue nil
  abort "Schedule not saved" unless setting.reload.auto_sync_enabled? && setting.sync_interval_minutes == 15
  # Simulate reaching the configured deadline without waiting 15 minutes.
  setting.update_columns(next_sync_at: 1.second.ago)
  wait.until do
    run = project.mirror_sync_runs.where(trigger: "automatic").order(:id).last
    abort "Automatic import failed: #{run.error_message}" if run&.status == "failed"
    run&.status == "succeeded"
  end
  automatic = project.mirror_sync_runs.where(trigger: "automatic").last
  abort "Automatic import not idempotent" unless automatic.log_events.all? { |event| event["action"] == "unchanged" }
  abort "Next deadline not scheduled" unless setting.reload.next_sync_at > Time.current
  driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/mirror/synchronizations/#{automatic.id}")
  abort "Log not visible" unless driver.page_source.include?("unchanged")
  puts "Synchronization smoke passed: browser preview, manual import, worker logs, automatic due execution, no duplicates and next deadline"
ensure
  driver.quit
  setting.update_columns(auto_sync_enabled: false)
  # Do not destroy a project while a worker still holds its execution lease.
  if setting.reload.running_run_id.nil?
    key = Digest::SHA256.hexdigest(JSON.generate([setting.source_url, setting.source_project_id, ENV.fetch("MIRROR_DESTINATION_URL"), project.id]))
    project.destroy!
    MirrorMapping.where(connection_key: key).delete_all
  end
end
