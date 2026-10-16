# frozen_string_literal: true
# File: redmine_mirror/test/environment/relations_ui_smoke.rb
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

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
require "selenium-webdriver"
project = Project.find_by!(identifier: "mirror-demo")
setting = project.mirror_project_setting
previous = setting.module_options
options = Selenium::WebDriver::Chrome::Options.new
%w[--headless --no-sandbox --disable-dev-shm-usage].each { |flag| options.add_argument(flag) }
options.binary = "/usr/bin/chromium"
driver = Selenium::WebDriver.for(:chrome, options: options, service: Selenium::WebDriver::Chrome::Service.new(path: "/usr/bin/chromedriver"))
wait = Selenium::WebDriver::Wait.new(timeout: 30)
begin
  driver.navigate.to("http://gateway:3102/login")
  driver.find_element(id: "username").send_keys("admin")
  driver.find_element(id: "password").send_keys("Mirror-test-2026!")
  driver.find_element(name: "login").click
  wait.until { driver.find_elements(id: "loggedas").any? }
  driver.navigate.to("http://gateway:3102/projects/mirror-demo/mirror/settings?tab=issue_relations")
  wait.until { driver.find_elements(id: "mirror-pending-relations").any? }
  raise "Pending rows not visible: #{driver.current_url}, #{driver.title}, tables=#{driver.find_elements(id: 'mirror-pending-relations').size}" unless driver.find_elements(css: "#mirror-pending-relations tbody tr").size == 2
  raise "Source issue links missing" unless driver.find_elements(css: '#mirror-pending-relations tbody tr td:first-child a[href="http://localhost:3101/issues/1"]').size == 2
  raise "Remote target links missing" unless driver.find_elements(css: '#mirror-pending-relations tbody tr td:nth-child(4) a[href^="http://localhost:3101/issues/"]').size == 2
  driver.navigate.to("http://gateway:3102/projects/mirror-demo/mirror/settings?tab=synchronization")
  raise "Pending counter missing" unless driver.find_elements(css: 'a[href*="tab=issue_relations"]').any? { |link| link.text.include?("2") }
  driver.navigate.to("http://gateway:3102/projects/mirror-demo/mirror/settings?tab=issue_relations")
  Selenium::WebDriver::Support::Select.new(driver.find_element(id: "missing_target")).select_by(:value, "note")
  driver.find_element(css: 'form[action$="/modules/issue_relations"] [type="submit"]').click
  wait.until { driver.find_elements(id: "flash_notice").any? }
  raise "Policy not saved" unless setting.reload.module_options.dig("issue_relations", "missing_target") == "note"
  issue = project.issues.find_by!(subject: "Mirror demo issue 1")
  driver.navigate.to("http://gateway:3102/issues/#{issue.id}")
  raise "Source issue link missing" unless driver.find_elements(css: '#mirror-issue-origin a[href="http://localhost:3101/issues/1"]').size == 1
  text = driver.find_element(id: "relations").text
  raise "Child relation not visible" unless text.include?("mirror-child-a issue 1")
  raise "Independent relation not visible" unless text.include?("mirror-independent issue 1")
  puts "Relations UI smoke passed: project policy saved and child/independent links visible on issue #{issue.id}"
ensure
  setting.update!(module_options: previous)
  driver.quit
end
