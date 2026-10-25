# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/02_destination_setup.rb
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
# Mirror RM4 -> RM5 migration demo, destination side (Redmine 5): guide steps 7 to 9.
# Reads the source mirror-reader API key on STDIN. Touches only the "mirror-demo" project
# and gives the project manager existing roles; adds the RM4 preprod to the allowed
# sources. Idempotent. Later modules (news, tags, agile, queries) are selected in Settings → Mirror.
abort "Redmine 5 destination only" unless Redmine::VERSION::MAJOR >= 5
SOURCE_URL = ENV.fetch("MIRROR_DEMO_SOURCE_URL")
api_key = $stdin.read.to_s.strip
abort "No source API key on STDIN" unless api_key.match?(/\A\h{40}\z/)

ActionMailer::Base.perform_deliveries = false
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
User.current = owner

settings = Setting.plugin_redmine_mirror.to_h
unless RedmineMirror.allowed_source_urls.include?(SOURCE_URL)
  Setting.plugin_redmine_mirror = settings.merge("allowed_source_urls" => [settings["allowed_source_urls"].to_s.strip, SOURCE_URL].reject(&:empty?).join("\n"))
end

# Existing roles of this Redmine: the project manager's, who also receives the time of
# developers and of anonymized authors (MIRROR_DEMO_ROLES, comma separated).
roles = Role.where(name: ENV.fetch("MIRROR_DEMO_ROLES").split(",").map(&:strip)).to_a
abort "None of the MIRROR_DEMO_ROLES exists here" if roles.empty?

project = Project.find_by(identifier: "mirror-demo") || Project.new(name: "Mirror demo (migration RM4 → RM5)",
  description: "Destination of the Mirror migration test from the Redmine 4 source. Demo data.", is_public: false).tap do |row|
  row.identifier = "mirror-demo"
  row.enabled_module_names = %w[issue_tracking time_tracking documents files wiki news agile mirror]
  row.trackers = Tracker.where(name: %w[Bug Feature Task])
  row.available_custom_fields.select(&:is_required?).each { |field| row.custom_field_values = { field.id.to_s => "0" } }
  row.save!
end
# Only an administrator may assign any role.
User.current = User.active.find_by!(admin: true)
Member.find_or_create_by!(project: project, user_id: owner.id) { |row| row.roles = roles }
User.current = owner

setting = project.mirror_project_setting || MirrorProjectSetting.new(project: project)
if setting.new_record?
  setting.source_url = SOURCE_URL
  setting.source_project_id = Integer(ENV.fetch("MIRROR_DEMO_SOURCE_PROJECT_ID"))
  setting.source_project_identifier = "mirror-demo"
  setting.source_text_format = "textile"
  setting.on_error = "skip"
  setting.selected_modules = %w[users issue_categories project_versions issue_tracking issue_journals issue_attachments
    issue_watchers issue_relations issue_hierarchy time_tracking wiki project_files documents]
  setting.api_key = api_key
  setting.save!
  setting.request_catalog_refresh!
end
puts "mirror-demo (id #{project.id}) connected to #{setting.source_url}/projects/mirror-demo; " \
  "modules: #{setting.selected_modules.join(', ')}; catalog: #{setting.reload.catalog_status}"
