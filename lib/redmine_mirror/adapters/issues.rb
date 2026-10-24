# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/issues.rb
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
# Import managed issue fields through REST and restore historical metadata locally.

require "time"

module RedmineMirror
  module Adapters
    class Issues < Base
      def initialize(users: Users.new)
        @user_adapter = users
      end

      def dependencies; ["users"]; end

      def referenced_users(record)
        %w[assigned_to author].filter_map { |field| record[field] }
      end

      def catalog_references(client, project_id)
        project = client.get("projects/#{Integer(project_id)}.json", "include" => "trackers").fetch("project")
        { "tracker" => project.fetch("trackers", []),
          "status" => client.get("issue_statuses.json").fetch("issue_statuses"),
          "priority" => client.get("enumerations/issue_priorities.json").fetch("issue_priorities") }
      end

      def mapping_tables
        [MappingTable.new("tracker"), MappingTable.new("status"), MappingTable.new("priority")]
      end

      def key; "issue_tracking"; end
      def project_module; :issue_tracking; end
      def text_samples(record); [record["description"]]; end
      def collection; "issues"; end
      def entity; "issue"; end
      METADATA_FIELDS = %w[is_private author_id created_on updated_on closed_on].freeze

      def fields; %w[subject description start_date due_date done_ratio estimated_hours tracker_id status_id priority_id assigned_to_id category_id fixed_version_id] + METADATA_FIELDS; end

      # Include closed issues but exclude descendants: every project has its own
      # correspondence namespace, configuration and independent synchronization.
      def filters(project_id)
        super.merge("status_id" => "*", "subproject_id" => "!*", "sort" => "id:asc")
      end

      # A tracker or status mapped to "ignore": its issues, and what belongs to them, are
      # not imported.
      def ignored_reference(record, mappings)
        %w[tracker status].find { |kind| ignored_mapping?(mappings, kind, record.dig(kind, "id")) }
      end

      def payload(record, project_id, mappings, lookup, options: {})
        result = record.slice("subject", "description", "start_date", "due_date", "done_ratio", "estimated_hours")
        result["description"] = TextFormat.convert(result["description"]) if result.key?("description")
        %w[tracker status].each do |kind|
          result["#{kind}_id"] = map(mappings, kind, record.fetch(kind).fetch("id"))
        end
        result["priority_id"] = priority_id(record, project_id, mappings)
        result["assigned_to_id"] = record["assigned_to"] ? @user_adapter.resolve(mappings, record["assigned_to"].fetch("id")) : nil
        { "category" => "issue_categories", "fixed_version" => "project_versions" }.each do |field, module_key|
          result["#{field}_id"] = record[field] && lookup.call(module_key, record[field].fetch("id"))
          if record[field] && !result["#{field}_id"]
            raise Error.new("Missing #{field} correspondence for source issue ##{record['id']} (#{field} ##{record[field]['id']} " \
              "#{record[field]['name'].inspect}); select its module, or synchronize the source project that owns it first",
              details: { "code" => "missing_reference", "field" => field, "id" => record[field]["id"].to_s, "name" => record[field]["name"].to_s })
          end
        end
        result["is_private"] = record.fetch("is_private", false)
        result["author_id"] = @user_adapter.resolve(mappings, record["author"].fetch("id")) if record["author"]
        %w[created_on updated_on closed_on].each do |field|
          next unless record.key?(field)
          value = record[field]
          begin
            result[field] = value && Time.iso8601(value).utc.iso8601
          rescue ArgumentError, TypeError
            raise Error, "Invalid source issue date #{field}"
          end
        end
        result.merge("project_id" => project_id)
      end

      # The Priorities table, unless a source custom field feeds the priority.
      def priority_id(record, project_id, mappings)
        fields = CustomFields.new
        project = mappings.fetch("custom_field", {}).value?(CustomFields::PRIORITY) && Project.find(project_id)
        source_id = project && fields.priority_source(mappings, project)
        return map(mappings, "priority", record.fetch("priority").fetch("id")) unless source_id
        value = record.fetch("custom_fields", []).find { |field| field["id"].to_s == source_id }&.fetch("value", nil)
        fields.priority_for(value, source_id: source_id, project: project)
      end

      # Redmine's REST API refuses a locked assignee and a version that is not open,
      # although an existing issue keeps both when they are locked or closed later.
      # Those references are held back from the API write and restored locally.
      def rest_attributes(payload)
        held = local_references(payload)
        held.empty? ? payload : payload.except(*held)
      end

      def local_references(payload)
        held = []
        assignee = payload["assigned_to_id"]
        held << "assigned_to_id" if RedmineMirror.inactive_user?(assignee)
        version_id = payload["fixed_version_id"]
        if version_id.is_a?(Integer)
          version = Version.find_by(id: version_id)
          raise Error, "Version ##{version_id} is not shared with the destination project" unless version && Project.find(payload.fetch("project_id")).shared_versions.include?(version)
          held << "fixed_version_id" unless version.open?
        end
        held
      end

      # REST creation uses the API actor and current timestamps. Restore validated
      # historical metadata locally without triggering another journal or notification.
      def restore_metadata(payload, target_id, project_id)
        issue = Issue.where(project_id: project_id).find(target_id)
        values = payload.slice(*METADATA_FIELDS, *local_references(payload))
        values["author_id"] ||= User.anonymous.id if payload.key?("author_id")
        %w[created_on updated_on closed_on].each do |field|
          values[field] = values[field] && Time.iso8601(values[field]) if values.key?(field)
        end
        issue.update_columns(values)
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "issues/#{Integer(source_id)}.json", source_project_id: source_project_id)
      end

      # Redmine also deletes the issue's history, files, time entries, relations and subtasks.
      def delete_local(destination_id, project_id)
        Issue.where(project_id: project_id).find_by(id: destination_id)&.destroy
      end

      def destination_attributes(record)
        result = super
        %w[tracker status priority assigned_to author category fixed_version].each do |kind|
          result["#{kind}_id"] = record[kind] && record[kind]["id"]
        end
        result
      end
    end

  end
end
