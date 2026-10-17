# frozen_string_literal: true
# File: redmine_mirror/test/environment/formats/formats_smoke.rb
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
# Import the Textile, Markdown and CKEditor source projects into a CKEditor destination
# with the source text format on Auto, then check the stored HTML and how it renders.

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
require "selenium-webdriver"
abort "The destination needs the CKEditor plugin" unless Redmine::WikiFormatting.format_names.include?("CKEditor")
Setting.text_formatting = "CKEditor"
admin = User.find_by!(login: "admin")
User.current = admin
alice = User.find_by!(login: "alice")
source_url = "http://source:3000"
source = RedmineMirror::Client.new(url: source_url, api_key: "1" * 40, allow_http: true)
destination_url = ENV.fetch("MIRROR_DESTINATION_URL")
destination = RedmineMirror::Client.new(url: destination_url, api_key: ENV.fetch("MIRROR_DESTINATION_API_KEY"), allow_http: true)
formatted = IssueCustomField.find_or_create_by!(name: "Local formatted notes") do |field|
  field.field_format = "text"
  field.text_formatting = "full"
  field.is_for_all = true
  field.trackers = Tracker.all
end

def check(condition, message)
  abort "Formats smoke failed: #{message}" unless condition
end

# Map each source reference to the local object of the same name (demo data).
local = {
  "tracker" => Tracker.all.to_h { |row| [row.name, row.id] },
  "status" => IssueStatus.all.to_h { |row| [row.name, row.id] },
  "priority" => IssuePriority.all.to_h { |row| [row.name, row.id] },
  "user" => { "Alice Mirror" => alice.id },
  "custom_field" => { "Mirror formatted notes" => formatted.id }
}
projects = {}
begin
  %w[textile markdown html].each do |format|
    identifier = "mirror-format-#{format}"
    remote = source.get("projects/#{identifier}.json").fetch("project")
    project = Project.create!(name: "Formats #{format}", identifier: "formats-#{format}-#{SecureRandom.hex(3)}",
      enabled_module_names: %w[mirror issue_tracking])
    project.trackers = Tracker.all
    Member.create!(project: project, user: alice, roles: [Role.find_by!(name: "Manager")])
    projects[format] = project
    setting = MirrorProjectSetting.new(project: project, source_url: source_url, source_project_id: remote.fetch("id"),
      source_project_identifier: identifier, source_text_format: "auto")
    setting.api_key = "1" * 40
    setting.selected_modules = %w[issue_tracking issue_journals issue_attachments issue_custom_fields]
    setting.source_catalog = RedmineMirror::SourceCatalog.new(client: source, project_id: remote.fetch("id"), adapters: setting.adapters).fetch
    setting.save!
    local.each do |kind, targets|
      setting.source_catalog.fetch(kind, {}).each do |id, name|
        target = targets[name]
        mode = target ? "existing" : (kind == "user" ? "anonymous" : nil)
        next unless mode
        project.mirror_reference_mappings.create!(reference_type: kind, source_id: id, destination_id: target, mode: mode)
      end
    end
    counts = setting.source_catalog.fetch("text_formats")
    check counts.key?(format), "#{format} not detected: #{counts}"
    config = setting.reload.synchronization_config(destination_url: destination_url)
    check config.dig("text_format", "target") == "CKEditor", "destination format #{config['text_format']}"
    key = Digest::SHA256.hexdigest(JSON.generate([source_url, remote.fetch("id"), destination_url, project.id]))
    runner = RedmineMirror::Runner.new(source: source, destination: destination, store: RedmineMirror::DatabaseStore.new(key, project_id: project.id))
    runner.run(config, apply: true)
    check runner.run(config).all? { |event| event[:action] == "unchanged" }, "#{format} rerun is not unchanged"
    puts "#{format}: detected #{counts.sort.to_h}, imported #{project.issues.count} issues"
  end

  textile = projects.fetch("textile").issues.find_by!(subject: "Textile constructs")
  %w[<h2>Release\ notes</h2> <strong>Bold</strong> <code> <table> <blockquote> <img\ src="textile-red.png"].each do |fragment|
    check textile.description.include?(fragment), "Textile description lacks #{fragment}"
  end
  check textile.description.include?("[[Wiki page]]") && textile.description.include?("{{toc}}"), "Redmine syntax lost"
  check textile.journals.map(&:notes).any? { |notes| notes.include?("<strong>bold</strong>") }, "Textile note not converted"
  check textile.custom_field_value(formatted).to_s.include?("<strong>bold</strong>"), "Formatted custom field not converted"
  check textile.attachments.map(&:filename) == ["textile-red.png"], "attachment missing"

  markdown = projects.fetch("markdown").issues.find_by!(subject: "Markdown constructs")
  %w[<h2> <strong>Bold</strong> <code>inline\ code</code> <del>strike</del>].each do |fragment|
    check markdown.description.include?(fragment), "Markdown description lacks #{fragment}"
  end

  html = projects.fetch("html")
  ckeditor = html.issues.find_by!(subject: "CKEditor constructs")
  remote_html = source.get("issues.json", "project_id" => "mirror-format-html", "status_id" => "*", "subject" => "CKEditor constructs")
  check ckeditor.description.start_with?("<h2>Release notes</h2>"), "HTML description changed"
  older = html.issues.find_by!(subject: "Written before the switch to CKEditor")
  check older.description.include?("<h3>Old Textile text</h3>"), "Textile text in an HTML project not converted"
  check older.journals.map(&:notes).include?("<p>New <strong>HTML</strong> note</p>"), "HTML note changed"
  check older.journals.map(&:notes).any? { |notes| notes.include?("Old <strong>Textile</strong> note") }, "Old Textile note not converted"
  check textile.journals.map(&:notes).any? { |notes| notes.include?("Indented paragraph") && notes.start_with?("<p") }, "second Textile note missing"

  # Rendering through the CKEditor formatter: bold text and the inline attachment image.
  options = Selenium::WebDriver::Chrome::Options.new
  %w[--headless --no-sandbox --disable-dev-shm-usage].each { |flag| options.add_argument(flag) }
  options.binary = "/usr/bin/chromium"
  driver = Selenium::WebDriver.for(:chrome, options: options, service: Selenium::WebDriver::Chrome::Service.new(path: "/usr/bin/chromedriver"))
  begin
    driver.navigate.to("http://gateway:3102/login")
    driver.find_element(id: "username").send_keys("admin")
    driver.find_element(id: "password").send_keys("Mirror-test-2026!")
    driver.find_element(name: "login").click
    Selenium::WebDriver::Wait.new(timeout: 20).until { driver.find_elements(id: "loggedas").any? }
    driver.navigate.to("http://gateway:3102/issues/#{textile.id}")
    description = driver.find_element(css: ".issue .description .wiki")
    check description.find_elements(css: "strong").map(&:text).include?("Bold"), "bold not rendered"
    image = description.find_elements(css: "img").find { |node| node.attribute("src").to_s.include?("/attachments/download/#{textile.attachments.first.id}/") }
    check image, "inline attachment image not resolved"
    driver.save_screenshot("/mirror-data/formats-textile-issue.png")
  ensure
    driver.quit
  end
  puts "Formats smoke passed: Textile, Markdown and mixed HTML texts converted to CKEditor HTML, notes and formatted custom fields, rendering and attachments"
ensure
  # FORMATS_KEEP=1 keeps the imported projects for inspection.
  projects.each_value do |project|
    next if ENV["FORMATS_KEEP"] == "1"
    keys = MirrorMapping.where(project_id: project.id).distinct.pluck(:connection_key)
    project.destroy
    MirrorMapping.where(connection_key: keys).delete_all
  end
  Setting.text_formatting = "textile"
end
