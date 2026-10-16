# frozen_string_literal: true
# File: redmine_mirror/test/environment/tabs_ui_smoke.rb
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
options = Selenium::WebDriver::Chrome::Options.new
%w[--headless --no-sandbox --disable-dev-shm-usage --disable-gpu].each { |flag| options.add_argument(flag) }
options.binary = "/usr/bin/chromium"
service = Selenium::WebDriver::Chrome::Service.new(path: "/usr/bin/chromedriver")
driver = Selenium::WebDriver.for(:chrome, options: options, service: service)
wait = Selenium::WebDriver::Wait.new(timeout: 20)
begin
  driver.navigate.to("http://gateway:3102/login")
  driver.find_element(id: "username").send_keys("admin")
  driver.find_element(id: "password").send_keys("Mirror-test-2026!")
  driver.find_element(name: "login").click
  wait.until { driver.find_elements(id: "loggedas").any? }
  driver.navigate.to("http://gateway:3102/projects/mirror-demo/mirror/settings?tab=users")
  [800, 1280, 1920].each do |width|
    driver.manage.window.resize_to(width, 900)
    visible = driver.execute_script(<<~JS)
      const box = document.querySelector('#mirror-settings-subtabs').getBoundingClientRect();
      return [...document.querySelectorAll('#mirror-settings-subtabs a')].every(link => {
        const rect = link.getBoundingClientRect();
        return rect.top >= box.top && rect.bottom <= box.bottom + 1 && rect.right <= box.right + 1;
      });
    JS
    raise "Clipped tabs at #{width}" unless visible
    driver.save_screenshot("/mirror-data/mirror-tabs-#{width}.png")
  end
  demo = ENV.fetch("MIRROR_CONFLICT_DEMO_PROJECT")
  raise "Invalid demo identifier" unless demo.match?(/\Aconflict-demo-[a-f0-9]+\z/)
  driver.navigate.to("http://gateway:3102/projects/#{demo}/mirror/settings?tab=conflicts")
  raise "Expected three demo conflicts" unless driver.find_elements(css: "#mirror-conflicts tbody tr").size == 3
  driver.save_screenshot("/mirror-data/mirror-conflicts-demo.png")
  puts "Tabs UI passed at 800/1280/1920; three real demo conflicts visible"
ensure
  driver.quit
end
