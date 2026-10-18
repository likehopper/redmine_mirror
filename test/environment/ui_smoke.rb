# frozen_string_literal: true
# File: redmine_mirror/test/environment/ui_smoke.rb
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

# Run only in the destination test container; preserves manual issue/time data.
abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
require "json"
require "selenium-webdriver"
config = JSON.parse(File.read(ENV.fetch("MIRROR_CONFIG")))
options = Selenium::WebDriver::Chrome::Options.new
%w[--headless --no-sandbox --disable-dev-shm-usage --disable-gpu].each { |flag| options.add_argument(flag) }
options.binary = "/usr/bin/chromium"
service = Selenium::WebDriver::Chrome::Service.new(path: "/usr/bin/chromedriver")
driver = Selenium::WebDriver.for(:chrome, options: options, service: service)
wait = Selenium::WebDriver::Wait.new(timeout: 20)
# The worker refreshes the source references after a save or a refresh request.
ActiveRecord::Base.connection.disable_query_cache!
wait_catalog = lambda do
  Selenium::WebDriver::Wait.new(timeout: 300, interval: 3).until do
    setting = Project.find_by!(identifier: "mirror-demo").mirror_project_setting&.reload
    abort "Catalog refresh failed: #{setting.catalog_error}" if setting&.catalog_status == "failed"
    setting&.catalog_status == "ready"
  end
end
# Same-version instances are seeded with identical IDs. Across Redmine versions the IDs
# differ, so fall back to the local object named like the source one.
choose = lambda do |select, value|
  menu = Selenium::WebDriver::Support::Select.new(select)
  next menu.select_by(:value, value) if menu.options.any? { |option| option.attribute("value") == value }
  name = select.find_element(xpath: "ancestor::tr/td[1]").text.sub(/ \(#\d+\)\z/, "")
  option = menu.options.find { |entry| entry.text.sub(/ \(#\d+\)\z/, "") == name }
  # A source account without a local member (the administrator, in a fresh stack) is anonymized.
  option ||= menu.options.find { |entry| entry.attribute("value") == "anonymous" }
  abort "No local match for #{select.attribute('name')} (#{name})" unless option
  menu.select_by(:value, option.attribute("value"))
end
# The configuration is the Mirror tab of the project settings, beside Redmine's own tabs.
in_tab = ->(css) { driver.find_element(css: "#tab-content-mirror #{css}") }
begin
  base = "http://gateway:3102"
  settings = "#{base}/projects/mirror-demo/settings/mirror"
  driver.navigate.to("#{base}/login")
  driver.find_element(id: "username").send_keys("admin")
  driver.find_element(id: "password").send_keys("Mirror-test-2026!")
  driver.find_element(name: "login").click
  wait.until { driver.find_elements(id: "loggedas").any? }
  driver.navigate.to(settings)
  if driver.find_element(name: "connection[source_url]").attribute("value").empty?
    driver.find_element(name: "connection[source_url]").send_keys(config.fetch("source_url"))
    driver.find_element(name: "connection[source_project_id]").send_keys(config.fetch("source_project_id").to_s)
    driver.find_element(name: "connection[api_key]").send_keys(ENV.fetch("MIRROR_SOURCE_API_KEY"))
    in_tab.call('input[value="time_tracking"]').click
    in_tab.call("[name=commit]").click
    wait.until { driver.find_elements(css: "#mirror-settings-subtabs a[href*='mirror_tab=users']").any? }
    wait_catalog.call
    %w[users issue_tracking time_tracking].each do |key|
      driver.navigate.to("#{settings}?mirror_tab=#{key}")
      driver.find_elements(css: 'select[name^="mappings["]').each do |select|
        kind, source_id = select.attribute("name").scan(/\[([^\]]+)\]/).flatten
        choose.call(select, config.fetch("mappings").fetch(kind, {}).fetch(source_id, "").to_s)
      end
      in_tab.call("[name=commit]").click
      wait.until { driver.find_elements(id: "flash_notice").any? }
    end
  end
  if ENV["MIRROR_ENABLE_HISTORY"] == "1"
    driver.navigate.to(settings)
    %w[issue_journals issue_attachments].each do |key|
      checkbox = in_tab.call("input[value='#{key}']")
      checkbox.click unless checkbox.selected?
    end
    in_tab.call("[name=commit]").click
    wait.until { driver.find_elements(id: "flash_notice").any? }
    wait_catalog.call
    driver.navigate.to("#{settings}?mirror_tab=users")
    # The source administrator is intentionally anonymized in this demo project.
    Selenium::WebDriver::Support::Select.new(driver.find_element(id: "mirror-user-1")).select_by(:value, "anonymous")
    in_tab.call("[name=commit]").click
    wait.until { driver.find_elements(id: "flash_notice").any? }
  end
  if ENV["MIRROR_REFRESH_TEST"] == "1"
    driver.navigate.to(settings)
    in_tab.call("form[action$='/refresh'] [type='submit']").click
    wait.until { driver.find_elements(id: "flash_notice").any? }
    wait_catalog.call
  end
  driver.navigate.to(settings)
  modules = Project.find_by!(identifier: "mirror-demo").mirror_project_setting.selected_modules
  abort "Expected connection, schedule and module tabs" unless driver.find_elements(css: "#mirror-settings-subtabs li").size == modules.size + 2
  driver.find_element(css: "#mirror-settings-subtabs a[href*='mirror_tab=users']").click
  wait.until { driver.find_elements(id: "mirror-table-user").any? }
  driver.navigate.to("#{base}/projects/mirror-demo/mirror")
  abort "Missing Mirror page tabs" unless driver.find_elements(css: "#mirror-page-tabs a[href*='tab=objects']").any?
  driver.navigate.to("#{settings}?mirror_tab=issue_tracking")
  if ENV["MIRROR_COMPLETE_STATUS_MAPPINGS"] == "1"
    driver.find_elements(css: 'select[name^="mappings[status]"]').each do |select|
      source_id = select.attribute("name").scan(/\[([^\]]+)\]/).flatten.last
      choose.call(select, config.fetch("mappings").fetch("status").fetch(source_id, "").to_s)
    end
    in_tab.call("[name=commit]").click
    wait.until { driver.find_elements(id: "flash_notice").any? }
  end
  abort "Missing tracker correspondence table" unless driver.find_elements(id: "mirror-table-tracker").any?
  driver.navigate.to("#{settings}?mirror_tab=users")
  abort "Missing user correspondence table" unless driver.find_elements(id: "mirror-table-user").any?
  abort "API key leaked" if driver.page_source.include?(ENV.fetch("MIRROR_SOURCE_API_KEY"))
  driver.save_screenshot("/mirror-data/mirror-mappings.png")
  puts "Manual UI smoke passed: login, connection, module tabs and saved project correspondences"
ensure
  driver.quit
end
