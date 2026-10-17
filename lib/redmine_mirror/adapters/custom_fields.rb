# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/custom_fields.rb
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
# Map existing compatible field definitions and translate current and historical values.

module RedmineMirror
  class CustomFieldMappingTable < MappingTable
    def initialize; super("custom_field", reference_fields: []); end
    def ignore_allowed?; true; end
    def metadata_fields; %w[field_format multiple possible_values observed]; end
    def local_records(project); project.all_issue_custom_fields.select { |field| field.visible_by?(project, User.current) }; end
  end

  module Adapters
    class CustomFields < IssueState
      SCALAR_FORMATS = %w[string text int float date bool link].freeze
      def key; "issue_custom_fields"; end
      def mapping_tables; [CustomFieldMappingTable.new]; end

      # Redmine restricts custom field definitions to administrators. Without them,
      # nil selects the observed mode: fields and values come from the issues.
      def definitions(client)
        client.get("custom_fields.json").fetch("custom_fields")
      rescue Error => error
        raise unless error.message.start_with?("Redmine API returned HTTP 403")
        nil
      end

      # A source definition known from an administrator key, or else the destination
      # field's format, which then decides how observed values are read.
      def effective_format(definition, field)
        definition["field_format"] || field.field_format
      end

      def list_values?(definition, field)
        %w[list enumeration].include?(effective_format(definition, field))
      end
      def records(client, project_id); Issues.new.records(client, project_id); end
      def empty_state; {}; end
      def accept_existing_state?; true; end

      # Historical values can survive after removal from the current source list.
      # Include them so journal translation can use explicit value correspondences.
      def catalog_references(client, project_id)
        observed = Hash.new { |hash, id| hash[id] = [] }
        seen = {}
        records(client, project_id).each do |issue|
          issue.fetch("custom_fields", []).each do |field|
            observed[field.fetch("id")].concat(Array(field["value"]))
            seen[field.fetch("id")] ||= { "id" => field.fetch("id"), "name" => field["name"], "multiple" => !!field["multiple"] }
          end
          detailed = issue_detail(client, issue.fetch("id"), "journals")
          detailed.fetch("journals", []).each do |journal|
            journal.fetch("details", []).select { |detail| detail["property"] == "cf" }.each do |detail|
              observed[Integer(detail.fetch("name"))].concat([detail["old_value"], detail["new_value"]].compact)
            end
          end
        end
        available = definitions(client)
        if available.nil?
          # Observed mode: formats are unknown, list choices are the values met in the issues.
          fields = observed.keys.map do |id|
            values = observed.fetch(id).reject { |value| value.to_s.empty? }.map(&:to_s).uniq
            (seen[id] || { "id" => id, "name" => "##{id}", "multiple" => false }).merge("field_format" => nil, "observed" => true,
              "possible_values" => values.map { |value| { "value" => value, "label" => value } })
          end
          return { "custom_field" => fields }
        end
        fields = available.select do |field|
          field["customized_type"] == "issue" && observed.key?(field.fetch("id"))
        end
        users = []
        fields.each do |field|
          values = observed.fetch(field.fetch("id")).reject { |value| value.to_s.empty? }.map(&:to_s).uniq
          if %w[list enumeration].include?(field["field_format"])
            possible = field.fetch("possible_values", []).dup
            values.each { |value| possible << { "value" => value, "label" => value } unless possible.any? { |entry| entry["value"].to_s == value } }
            field["possible_values"] = possible
          elsif field["field_format"] == "user"
            users.concat(values.map do |id|
              user = client.get("users/#{Integer(id)}.json").fetch("user")
              { "id" => user.fetch("id"), "name" => [user["firstname"], user["lastname"]].compact.join(" ") }
            end)
          end
        end
        { "custom_field" => fields, "user" => users.uniq { |user| user.fetch("id") } }
      end

      def configuration_options(input, project)
        raise Error, "Unsupported custom field options" unless (input.keys - ["value_mappings"]).empty?
        values = input.fetch("value_mappings", {})
        raise Error, "Invalid custom field value mappings" unless values.is_a?(Hash)
        definitions = project.mirror_project_setting.source_catalog.fetch("custom_field_definitions", {})
        values.each do |id, entries|
          definition = definitions.fetch(id) { raise Error, "Unknown source custom field" }
          raise Error, "Invalid value mappings" unless entries.is_a?(Hash) && (definition["observed"] || %w[list enumeration].include?(definition["field_format"]))
          allowed = definition.fetch("possible_values", []).map { |value| value_key(value.fetch("value")) }
          raise Error, "Unknown source custom field value" unless (entries.keys - allowed).empty?
        end
        { "value_mappings" => values }
      end

      def digest(value); super(value.is_a?(Hash) ? value.sort.to_h : value); end

      def value_key(value); Digest::SHA256.hexdigest(value.to_s); end

      def ignored?(id, mappings); mappings.fetch("custom_field", {})[id.to_s] == "ignore"; end

      # Field definitions are administration-owned. Only resolve an existing field
      # available to this project; this adapter never creates definitions.
      def target_field(source_id, mappings, project)
        id = map(mappings, "custom_field", source_id)
        field = project.all_issue_custom_fields.find { |candidate| candidate.id == id }
        raise Error, "The destination custom field mapped to source field ##{source_id} is not enabled in this project" unless field
        field
      end

      # Compatible format and multiplicity are prerequisites. List/enumeration
      # values require explicit choices; user and version values reuse object mappings.
      def translate_value(value, source_id:, field:, definition:, options:, mappings:, lookup:)
        format = effective_format(definition, field)
        unless field.field_format == format && field.multiple? == !!definition["multiple"]
          raise Error, "Source custom field ##{source_id} and destination field \"#{field.name}\" have incompatible formats or multiplicity"
        end
        raise Error, "Unsupported custom field format #{format}" unless (SCALAR_FORMATS + %w[list enumeration user version]).include?(format)
        return value if value.nil? || value == "" || value == []
        translate = lambda do |entry|
          case format
          when "list", "enumeration"
            target = options.fetch("value_mappings", {}).fetch(source_id.to_s, {})[value_key(entry)]
            raise Error, "Missing value mapping for custom field source ID #{source_id}" if target.nil? || target.empty?
            permitted = field.possible_values_options.map { |label, id| (id || label).to_s }
            raise Error, "Invalid destination custom field value" unless permitted.include?(target.to_s)
            target.to_s
          when "user"
            Users.new.resolve(mappings, Integer(entry))&.to_s || ""
          when "version"
            target = lookup.call("project_versions", Integer(entry))
            raise Error, "Missing custom field version correspondence" unless target
            target.to_s
          when "text"
            # Long text fields with "Text formatting: full" follow the destination format.
            field.text_formatting == "full" ? TextFormat.convert(entry.to_s) : entry.to_s
          else entry.to_s
          end
        end
        translated = value.is_a?(Array) ? value.map(&translate).tap { |list| list.reject!(&:empty?) if format == "user" }.sort : translate.call(value)
        # The destination's own validation rejects a scalar value its format cannot hold,
        # before any write: the only format check left when source definitions are unknown.
        # Lists, users and versions are already checked through their correspondences.
        if SCALAR_FORMATS.include?(format)
          errors = field.validate_custom_value(CustomFieldValue.new(custom_field: field, customized: Issue.new, value: translated))
          raise Error, "Invalid value for custom field source ID #{source_id}: #{errors.join(', ')}" if errors.any?
        end
        translated
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        local_id = lookup.call("issue_tracking", record.fetch("id"))
        issue = Issue.find_by(id: local_id, project_id: project_id) unless local_id.to_s.start_with?("planned:")
        raise Error, "Missing destination issue correspondence" if apply && !issue
        desired = imported_values(record, project_id: project_id, mappings: mappings, lookup: lookup, issue: issue)
        event = { module: key, source_id: record.fetch("id"), destination_id: local_id, action: "update" }
        return event unless issue
        current = state(issue, desired.keys)
        raise Error, "Custom field value disappeared or mappings changed; manual resolution required" if store.find(key, record.fetch("id")) && desired.empty? && store.find(key, record.fetch("id")).fetch("source_fingerprint") != digest({})
        previous = store.find(key, record.fetch("id"))
        if !previous && current != desired
          defaults = state(Issue.new(project: issue.project, tracker: issue.tracker), desired.keys)
          raise Error, "Existing local custom field values require manual resolution" unless current == defaults
        end
        if previous && digest(current) != previous.fetch("destination_fingerprint")
          raise Error, "Local modification detected for #{key} source ID #{record.fetch('id')}"
        end
        event[:action] = current == desired ? "unchanged" : "update"
        issue.custom_field_values = desired
        raise Error, "Destination rejected custom field values: #{issue.errors.full_messages.join(', ')}" unless issue.valid?
        if apply
          MirrorMapping.transaction do
            if current != desired
              dates = issue.attributes.slice("created_on", "updated_on", "closed_on")
              issue.save!
              issue.reload.update_columns(dates)
            end
            actual = state(issue.reload, desired.keys)
            raise Error, "Destination did not preserve imported custom field values" unless actual == desired
            store.save(key, record.fetch("id"), "destination_id" => issue.id,
              "source_fingerprint" => digest(desired), "destination_fingerprint" => digest(actual))
          end
        end
        event
      end

      def imported_values(record, project_id:, mappings:, lookup:, issue: nil)
        project = Project.find(project_id)
        setting = project.mirror_project_setting
        definitions = setting.source_catalog.fetch("custom_field_definitions", {})
        options = setting.module_options.fetch(key, {})
        references = record.fetch("custom_fields", []).reject { |reference| ignored?(reference.fetch("id"), mappings) }
        # A value Mirror cannot write must not block the issue, its time entries and its
        # history: it is skipped with a warning, grouped by cause in the execution log.
        # Redmine still rejects an issue whose required field is left without a value.
        pairs = references.filter_map do |reference|
          id = reference.fetch("id")
          field = target_field(id, mappings, project)
          unavailable = if issue
            !issue.available_custom_fields.include?(field)
          elsif record["tracker"]
            !field.trackers.exists?(id: map(mappings, "tracker", record.fetch("tracker").fetch("id")))
          end
          if unavailable
            tracker = issue&.tracker || Tracker.find_by(id: map(mappings, "tracker", record.fetch("tracker").fetch("id")))
            raise Error, "Custom field \"#{field.name}\" is not enabled for destination tracker \"#{tracker&.name}\": enable it, or ignore source field ##{id}"
          end
          definition = definitions.fetch(id.to_s) { raise Error, "Refresh custom field references" }
          [field.id.to_s, translate_value((reference["value"] || (field.multiple? ? [] : "")), source_id: id, field: field, definition: definition, options: options, mappings: mappings, lookup: lookup)]
        rescue Error => error
          TextFormat.warning("#{error.message}; the value was not imported")
          nil
        end
        desired = pairs.to_h
        raise Error, "Multiple source fields map to the same destination field" if desired.size != pairs.size
        desired
      end

      def state(issue, ids)
        issue.custom_field_values.select { |value| ids.include?(value.custom_field_id.to_s) }.to_h do |value|
          raw = value.value
          [value.custom_field_id.to_s, raw.is_a?(Array) ? raw.map(&:to_s).sort : raw.to_s]
        end
      end
    end
  end
end
