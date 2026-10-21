# frozen_string_literal: true
# File: redmine_mirror/test/documentation/documentation_helpers.rb
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
# Browser helpers shared by the documentation tests: screenshots, login, mappings.

module MirrorDocumentationHelpers
  private

  # Selects the local reference named like the remote one, unless overridden.
  def map_by_name(table, overrides = {})
    within("#mirror-table-#{table}") do
      all("tbody tr").each do |row|
        name = row.find("td", match: :first).text.sub(/ \(#\d+\)\z/, "")
        # Special choices (anonymize, ignore) are checkboxes beside the field.
        next row.check(overrides[name]) if overrides.key?(name) && row.has_field?(overrides[name], type: "checkbox")
        field = row.find("select")
        choice = overrides.fetch(name) { field.all("option").map(&:text).find { |text| text.sub(/ \(#\d+\)(?: .*)?\z/, "") == name } }
        assert choice, "No local #{table} named #{name}"
        field.select(choice)
      end
    end
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
    File.binwrite(File.join(self.class::SCREENSHOTS, "#{name}.png"), Base64.decode64(data))
  ensure
    browser&.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
