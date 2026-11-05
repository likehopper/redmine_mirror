# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/project_enumerations.rb
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
# Copy the project enumerations (Project Enumerations plugin) of issue custom
# fields, so that issue values of those fields can be translated.

module RedmineMirror
  module Adapters
    # The plugin's API serves enumerations to their managers only: the source must run
    # Mirror and share them (Mirror source). Each enumeration belongs to a source issue
    # custom field mapped in this tab to a local field of the same format.
    class ProjectEnumerations < ProjectReferences
      SOURCE_VERSION = "1.0.0-beta.36"
      FORMAT = "project_enumeration"
      STATUSES = %w[open locked closed].freeze
      SHARINGS = %w[none descendants hierarchy tree system].freeze

      def key; "project_enumerations"; end
      def model; ::ProjectEnumeration; end
      def fields; %w[custom_field_id value status sharing position]; end
      def project_module; :issue_tracking; end
      def mapping_tables; [CustomFieldMappingTable.new]; end
      def selection_hint; :text_mirror_project_enumerations_source_hint; end

      # The destination needs the plugin too.
      def available?
        defined?(::ProjectEnumeration) ? true : false
      end

      REFUSALS = {
        "disabled" => "Mirror source is disabled on the source Redmine: its administrator must allow it, and this data (Administration → Plugins → Redmine Mirror)",
        "module" => "Enable the Mirror source module on the source project",
        "not_shared" => "Share Project enumerations in the source project's Settings → Mirror source",
        "permission" => "The source API key needs View issues in the source project",
        "unavailable" => "The source Redmine has no Project Enumerations plugin"
      }.freeze

      # Enumerations of issue fields only: time entry and project fields are not imported.
      def records(client, project_id)
        client.get("projects/#{Integer(project_id)}/mirror/source/project_enumerations.json").fetch("project_enumerations")
          .select { |row| row.dig("custom_field", "type").nil? || row.dig("custom_field", "type") == "IssueCustomField" }
          .map { |row| { "project" => { "id" => Integer(project_id) } }.merge(row) }.sort_by { |row| row.fetch("id") }
      rescue Error => error
        reason = error.message[/\(Mirror source: ([a-z_]+)\)/, 1]
        raise Error, REFUSALS.fetch(reason) if REFUSALS.key?(reason)
        raise Error, "The source Redmine does not list project enumerations: install Redmine Mirror #{SOURCE_VERSION} or later on it" if error.message.include?("HTTP 404")
        raise Error, REFUSALS.fetch("permission") if error.message.include?("HTTP 403") || error.message.include?("HTTP 401")
        raise
      end

      # The source fields of the enumerations, to map in this tab.
      def catalog_references(client, project_id)
        fields = records(client, project_id).map { |row| row.fetch("custom_field") }.uniq { |field| field.fetch("id") }
        { "custom_field" => fields.map { |field| { "id" => field.fetch("id"), "name" => field["name"], "field_format" => FORMAT, "multiple" => false } } }
      end

      # A field mapped to "ignore" leaves its enumerations out.
      def ignored_reference(record, mappings)
        mappings.fetch("custom_field", {})[record.dig("custom_field", "id").to_s] == "ignore" ? "custom_field" : nil
      end

      def attributes(record, mappings)
        source_field = record.fetch("custom_field").fetch("id")
        field = IssueCustomField.find_by(id: map(mappings, "custom_field", source_field))
        unless field && field.field_format == FORMAT
          raise Error, "Source custom field ##{source_field} must be mapped to a local project enumeration field"
        end
        { "custom_field_id" => field.id, "value" => record.fetch("value").to_s,
          "status" => STATUSES.include?(record["status"]) ? record["status"] : "open",
          "sharing" => SHARINGS.include?(record["sharing"]) ? record["sharing"] : "none",
          "position" => record["position"] }
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "mirror/source/project_enumerations/#{Integer(source_id)}.json", source_project_id: source_project_id)
      end

      def remote_path(_id, setting)
        "projects/#{setting.source_project_identifier.presence || setting.source_project_id}/settings/project_enumerations"
      end
    end
  end
end
