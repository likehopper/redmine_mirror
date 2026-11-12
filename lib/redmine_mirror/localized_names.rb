# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/localized_names.rb
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
# Read optional Localizable names as aliases. Mirror keeps reference IDs as identities;
# these names only make matching independent from the active locale.

module RedmineMirror
  module LocalizedNames
    module_function

    TYPES = %w[tracker status priority activity document_category role custom_field].freeze
    LOCALIZABLE_TYPES = { "tracker" => "tracker", "status" => "issue_status", "priority" => "enumeration",
      "activity" => "enumeration", "document_category" => "enumeration", "role" => "role",
      "custom_field" => "custom_field" }.freeze

    def record_names(type, record)
      names = [record[:name], record.name]
      names.concat(translations(type, record.id))
      names.map { |name| name.to_s.strip }.reject(&:empty?).uniq
    end

    def source_names(catalog, type, id, displayed_name)
      ([displayed_name] + Array(catalog.dig("reference_aliases", type, id.to_s))).map(&:to_s).reject(&:empty?).uniq
    end

    # Only names of references the project can use are exposed by Mirror source. The
    # Localizable settings themselves, languages and unrelated objects stay on the source.
    def source_aliases(project, user = User.current)
      TYPES.each_with_object({}) do |type, result|
        aliases = source_records(project, type, user).each_with_object({}) do |record, names|
          values = record_names(type, record)
          names[record.id.to_s] = values if values.many?
        end
        result[type] = aliases if aliases.any?
      end
    end

    def translations(type, id)
      key = LOCALIZABLE_TYPES[type]
      return [] unless key
      values = localizable_settings.dig("locales", key, id.to_s)
      values.respond_to?(:to_h) ? values.to_h.values : []
    end

    def localizable_settings
      value = Setting["plugin_localizable"]
      value.respond_to?(:to_h) ? value.to_h : {}
    rescue StandardError
      {}
    end

    def source_records(project, type, user = User.current)
      case type
      when "tracker" then project.trackers
      when "status" then project.rolled_up_statuses
      when "priority" then IssuePriority.active
      when "activity" then project.activities
      when "document_category" then DocumentCategory.shared.active
      when "role"
        if user.allowed_to?(:view_members, project)
          Role.where(id: MemberRole.joins(:member).where(members: { project_id: project.id }).select(:role_id))
        else
          []
        end
      when "custom_field" then project.all_issue_custom_fields.select { |field| field.visible_by?(project, user) }
      else []
      end.to_a
    end
  end
end
