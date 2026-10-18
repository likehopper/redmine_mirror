# frozen_string_literal: true
# File: redmine_mirror/test/environment/reporting_smoke.rb
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
# Check the redmine_reporting adapters between both instances, in steps driven by
# reporting_smoke.sh: REPORTING_SMOKE_STEP=import, update or cleanup.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
abort "Start the environment with compose.reporting.yml" unless Redmine::Plugin.installed?(:redmine_reporting)
require "selenium-webdriver"
# The worker writes from another process; polling must bypass Rails' query cache.
ActiveRecord::Base.connection.disable_query_cache!
STATE = "/mirror-data/reporting-smoke.json"
MODULES = %w[reporting_settings reporting_credit_policies].freeze
admin = User.find_by!(login: "admin")
source = RedmineMirror::Client.new(url: "http://source:3000", api_key: "1" * 40, allow_http: true)
source_project = source.get("projects/mirror-reporting-demo.json").fetch("project")
source_policies = RedmineMirror::REGISTRY["reporting_credit_policies"].records(source, source_project.fetch("id")).to_a
trackers = %w[Bug Feature Support].to_h { |name| [name, Tracker.find_by!(name: name)] }

def check(condition, message)
  abort "Reporting smoke failed: #{message}" unless condition
end

def wait_for_run(project, after_id)
  Selenium::WebDriver::Wait.new(timeout: 120, interval: 2).until do
    run = project.mirror_sync_runs.where("id > ?", after_id).order(:id).last
    run if run && %w[succeeded partial failed].include?(run.reload.status)
  end
end

# A run queued from the browser is executed by the worker service.
def browser_run(driver, project, mode)
  last = project.mirror_sync_runs.maximum(:id).to_i
  driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/mirror")
  driver.find_element(css: %(form[action$="/synchronizations"] input[value="#{mode}"])).find_element(xpath: "..").find_element(css: '[type="submit"]').click
  wait_for_run(project, last)
end

# Later runs go through the same queue, executed here rather than waiting for the worker.
def queued_run(project, user)
  run = RedmineMirror::Synchronization.enqueue(project.mirror_project_setting, apply: true, trigger: "manual", user: user)
  RedmineMirror::Synchronization.execute(run)
  wait_for_run(project, run.id - 1)
end

def actions(run)
  run.log_events.map { |event| [event.fetch("module"), event.fetch("action")] }.sort
end

def browser
  options = Selenium::WebDriver::Chrome::Options.new
  %w[--headless --no-sandbox --disable-dev-shm-usage].each { |flag| options.add_argument(flag) }
  options.binary = "/usr/bin/chromium"
  driver = Selenium::WebDriver.for(:chrome, options: options, service: Selenium::WebDriver::Chrome::Service.new(path: "/usr/bin/chromedriver"))
  driver.navigate.to("http://gateway:3102/login")
  driver.find_element(id: "username").send_keys("admin")
  driver.find_element(id: "password").send_keys("Mirror-test-2026!")
  driver.find_element(name: "login").click
  yield driver
ensure
  driver&.quit
end

def smoke_project
  Project.find_by!(identifier: JSON.parse(File.read(STATE)).fetch("identifier"))
end

case ENV.fetch("REPORTING_SMOKE_STEP")
when "import"
  child = source.get("projects/mirror-reporting-child.json").fetch("project")
  check RedmineMirror::REGISTRY["reporting_settings"].records(source, child.fetch("id")).empty?, "inherited settings are listed"
  project = Project.create!(name: "Reporting smoke", identifier: "reporting-smoke-#{SecureRandom.hex(4)}",
    enabled_module_names: %w[mirror reporting issue_tracking time_tracking])
  project.trackers = trackers.values
  File.write(STATE, JSON.generate("identifier" => project.identifier))
  setting = MirrorProjectSetting.new(project: project, source_url: "http://source:3000", source_project_id: source_project.fetch("id"))
  setting.selected_modules = MODULES
  setting.api_key = "1" * 40
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: source, project_id: source_project.fetch("id"), adapters: setting.adapters).fetch
  setting.save!
  browser do |driver|
    driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/settings/mirror")
    labels = driver.find_elements(css: "#mirror-connection-form label.block").map(&:text)
    check (["Reporting settings", "Reporting credit policies"] - labels).empty?, "modules missing from the connection tab: #{labels.inspect}"
    # Map each source tracker to the local tracker of the same name, in the module tab.
    driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/settings/mirror?mirror_tab=reporting_credit_policies")
    setting.source_catalog.fetch("tracker").each do |id, name|
      Selenium::WebDriver::Support::Select.new(driver.find_element(id: "mirror-tracker-#{id}")).select_by(:value, trackers.fetch(name).id.to_s)
    end
    driver.find_element(css: "#mirror-table-tracker").find_element(xpath: "ancestor::form").find_element(css: '[type="submit"]').click
    check project.mirror_reference_mappings.where(reference_type: "tracker").count == 3, "tracker mappings not saved"

    preview = browser_run(driver, project, "preview")
    check preview.status == "succeeded", "preview failed: #{preview.error_message}"
    check actions(preview) == [%w[reporting_credit_policies create]] * 2 + [%w[reporting_settings create]], "preview #{actions(preview)}"
    check ReportingProjectSetting.where(project_id: project.id).none? && project.reporting_credit_policies.none?, "the preview wrote data"

    import = browser_run(driver, project, "apply")
    check import.status == "succeeded", "import failed: #{import.error_message}"
    local = ReportingProjectSetting.find_by!(project_id: project.id)
    check [local.hours_per_day.to_f, local.section_ids, local.run_tracker_ids, local.build_tracker_ids] ==
          [7.0, %w[run workload], [trackers["Support"].id], [trackers["Feature"].id]], "settings #{local.attributes}"
    support = project.reporting_credit_policies.find_by!(tracker_id: trackers["Support"].id)
    check support.name == "Support contract" &&
          support.sorted_refills.map { |refill| [refill.month, refill.credit_days.to_f, refill.ends_on&.iso8601] } == [[7, 3.0, nil], [10, 2.0, "2026-12-31"]],
          "support policy"
    check project.reporting_credit_policies.find_by!(tracker_id: trackers["Feature"].id).active_until == Date.new(2027, 3, 31), "feature policy"

    driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/mirror?tab=objects")
    source_policy_links = source_policies.map { |policy| %(a[href="http://localhost:3101/projects/#{source_project.fetch('id')}/reporting/credit_policies/#{policy.fetch('id')}/edit"]) }
    check source_policy_links.all? { |css| driver.find_elements(css: css).any? }, "source policy links"
    check driver.find_elements(css: %(a[href^="/projects/#{project.identifier}/reporting/credit_policies/"])).size == 2, "local policy links"
    check driver.find_elements(css: %(a[href="/projects/#{project.identifier}/settings/reporting"])).any?, "local settings link"
    driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/settings/reporting")
    check driver.find_element(id: "tab-content-reporting").text.include?("Support contract"), "Reporting settings tab"
  end
  rerun = queued_run(project, admin)
  check rerun.status == "succeeded" && rerun.log_events.all? { |event| event["action"] == "unchanged" }, "rerun #{actions(rerun)}"
  puts "Reporting import passed: modules and tracker mappings in the UI, preview without writes, worker import, links, unchanged rerun"
when "update"
  project = smoke_project
  update = queued_run(project, admin)
  check update.status == "succeeded", "update failed: #{update.error_message}"
  check actions(update) == [%w[reporting_credit_policies unchanged], %w[reporting_credit_policies update], %w[reporting_settings update]], "update #{actions(update)}"
  support = project.reporting_credit_policies.find_by!(tracker_id: trackers["Support"].id)
  check ReportingProjectSetting.find_by!(project_id: project.id).hours_per_day.to_f == 6.0, "updated hours per day"
  check support.name == "Support contract 2027" && support.sorted_refills.first.credit_days.to_f == 4.0, "updated support policy"

  feature = project.reporting_credit_policies.find_by!(tracker_id: trackers["Feature"].id)
  feature.update!(initial_credit_days: 99)
  conflicted = queued_run(project, admin)
  check %w[failed partial].include?(conflicted.status) && conflicted.error_message.include?("Local modification"), "local change #{conflicted.error_message}"
  conflict = project.mirror_conflicts.find_by!(module_key: "reporting_credit_policies", status: "open")
  browser do |driver|
    driver.navigate.to("http://gateway:3102/projects/#{project.identifier}/mirror?tab=conflicts")
    driver.find_element(css: %(form[action$="/conflicts/#{conflict.id}"] input[name="resolution"][value="ignore"])).find_element(xpath: "..").find_element(css: '[type="submit"]').click
    driver.switch_to.alert.accept
    Selenium::WebDriver::Wait.new(timeout: 20).until { conflict.reload.status == "ignored" }
  end
  kept = queued_run(project, admin)
  check kept.status == "succeeded" && actions(kept).include?(%w[reporting_credit_policies ignored]), "kept #{actions(kept)}"
  check feature.reload.initial_credit_days.to_f == 99.0, "local policy overwritten"
  puts "Reporting update passed: source changes applied, local change reported as a conflict, local object kept"
when "cleanup"
  project = File.exist?(STATE) && Project.find_by(identifier: JSON.parse(File.read(STATE)).fetch("identifier"))
  if project
    setting = project.mirror_project_setting
    # Do not destroy a project while a worker still holds its execution lease.
    abort "A run is still in progress on #{project.identifier}" if setting&.reload&.running_run_id
    keys = MirrorMapping.where(project_id: project.id).distinct.pluck(:connection_key)
    project.destroy!
    MirrorMapping.where(connection_key: keys).delete_all
  end
  File.delete(STATE) if File.exist?(STATE)
  puts "Reporting smoke cleanup done"
else
  abort "Set REPORTING_SMOKE_STEP to import, update or cleanup"
end
