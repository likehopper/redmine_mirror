# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/journals.rb
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
# Translate historical changes, authors and private notes without sending notifications.

module RedmineMirror
  module Adapters
    class Journals < IssueChildren
      def key; "issue_journals"; end
      def phase; :history; end
      def association; "journals"; end
      def text_samples(record); [record["notes"]]; end

      # Historical status, tracker and priority changes need mappings too.
      def used_references(record)
        record.fetch("details", []).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |detail, used|
          name = detail["name"].to_s
          next unless detail["property"] == "attr" && %w[status_id tracker_id priority_id].include?(name)
          used[name.delete_suffix("_id")].concat(detail.values_at("old_value", "new_value").compact.reject(&:empty?))
        end
      end

      def imported_attributes(record, mappings, lookup: nil, project: nil)
        details = record.fetch("details", []).filter_map do |detail|
          property, name = detail.values_at("property", "name")
          if property == "cf"
            # As for current values, a custom field change Mirror cannot translate is
            # skipped with a warning; the journal and its notes are still imported.
            begin
              raise Error, "Select the custom fields module to import custom field history" unless project && mappings.key?("custom_field")
              adapter = CustomFields.new
              next if adapter.ignored?(name, mappings)
              field = adapter.target_field(Integer(name), mappings, project)
              setting = project.mirror_project_setting
              raise Error, "Select the custom fields module to import custom field history" unless setting.selected_modules.include?(adapter.key)
              definition = setting.source_catalog.fetch("custom_field_definitions", {}).fetch(name.to_s) { raise Error, "Refresh custom field references" }
              values = %w[old_value new_value].map do |key|
                adapter.translate_value(detail[key], source_id: name, field: field, definition: definition,
                  options: setting.module_options.fetch(adapter.key, {}), mappings: mappings, lookup: lookup)
              end
              next [property, field.id.to_s, *values]
            rescue Error => error
              TextFormat.warning("#{error.message}; the history change was not imported")
              next
            end
          end
          # Attachment and relation changes are imported by their own modules: skip the
          # detail, keep the journal (its notes and other changes).
          unless property == "attr"
            TextFormat.note("history_details_skipped")
            next
          end
          values = %w[old_value new_value].map do |field|
            value = detail[field]
            if value.present? && %w[status_id tracker_id priority_id assigned_to_id author_id].include?(name)
              kind = name.sub(/_id\z/, "")
              value = %w[assigned_to author].include?(kind) ? (Users.new.resolve(mappings, value.to_i) || User.anonymous.id).to_s : map(mappings, kind, value.to_i).to_s
            elsif value.present? && %w[category_id fixed_version_id].include?(name)
              key = name == "category_id" ? "issue_categories" : "project_versions"
              value = lookup && lookup.call(key, value.to_i)
              # A category or version deleted since, or owned by another project.
              next :skip unless value
              value = value.to_s
            elsif value.present? && name.end_with?("_id")
              # Parent and project changes (moved issues) have no local equivalent here.
              next :skip
            elsif value.present? && name == "description"
              value = TextFormat.convert(value)
            end
            value
          end
          if values.include?(:skip)
            TextFormat.note("history_details_skipped")
            next
          end
          [property, name, *values]
        end
        { "user_id" => author_id(record, mappings), "created_on" => Time.iso8601(record.fetch("created_on")).utc.iso8601,
          "notes" => TextFormat.convert(record["notes"].to_s), "private_notes" => !!record["private_notes"], "details" => details }
      end

      # A journal left with neither notes nor details would be an empty "Updated by" entry.
      def skip_reason(attributes)
        "Only history details that cannot be imported" if attributes.fetch("notes").strip.empty? && attributes.fetch("details").empty?
      end

      def find_target(id, issue)
        raise Error, "Missing destination issue" unless issue
        issue.journals.find(id)
      end

      def local_attributes(journal)
        { "user_id" => journal.user_id, "created_on" => journal.created_on.utc.iso8601,
          "notes" => journal.notes.to_s, "private_notes" => journal.private_notes,
          "details" => journal.details.order(:id).map { |detail| [detail.property, detail.prop_key, detail.old_value, detail.value] } }
      end

      def import(_record, attributes, issue, _source)
        journal = issue.journals.new(attributes.except("details"))
        journal.notify = false
        # redmine_ckeditor's mention notifications would add journals to the issues cited.
        journal.do_not_notify = true if journal.respond_to?(:do_not_notify=)
        attributes.fetch("details").each do |property, name, old_value, value|
          journal.details.build(property: property, prop_key: name, old_value: old_value, value: value)
        end
        journal.save!
        journal
      end
    end
  end
end
