# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/base.rb
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
# Define the REST adapter contract and validate required numeric reference mappings.

module RedmineMirror
  module Adapters
    class Base
      def selectable?
        true
      end

      def api_version
        ADAPTER_API_VERSION
      end

      # One of Registry::PHASES.
      def phase
        :default
      end

      # False when a prerequisite such as the plugin owning the data is missing
      # on this destination. Unavailable modules cannot be selected or run.
      def available?
        true
      end

      # Native destination path for a mapped object, or nil to display the ID only.
      def local_path(_id, _project)
        nil
      end

      # Source path relative to the source URL, or nil to display the ID only.
      def remote_path(_id, _setting)
        nil
      end

      # Redmine project module the destination project needs (e.g. :wiki), or nil. The
      # module tab warns when it is disabled.
      def project_module
        nil
      end

      # Locale key of a requirement shown next to the module in the connection form, or nil.
      def selection_hint
        nil
      end

      # Optional partial rendered in the module tab, above the mapping tables.
      def settings_partial
        nil
      end

      def referenced_users(_record)
        []
      end

      # Formatted texts of a record, sampled to report the source text formats.
      def text_samples(_record)
        []
      end

      # {table key => [source IDs]} referenced by a record beyond its mapping tables,
      # so the mapping forms can show only the references a project really uses.
      def used_references(_record)
        {}
      end

      def label
        "label_mirror_module_#{key}".to_sym
      end

      def catalog_references(_client, _project_id)
        {}
      end

      def mapping_tables
        []
      end

      def anonymous_time_user_required?
        false
      end

      def configuration_options(input, _project)
        raise Error, "Unsupported module options" unless input.empty?
        {}
      end

      def dependencies
        []
      end

      def records(client, project_id)
        client.each_record(collection, filters(project_id))
      end

      def filters(project_id)
        { "project_id" => project_id }
      end

      # An issue with its associations; test doubles may only answer the plain request.
      def issue_detail(client, id, association)
        return client.issue_detail(id) if client.respond_to?(:issue_detail)
        client.get("issues/#{Integer(id)}.json", "include" => association).fetch("issue")
      end

      def read(client, id)
        client.get("#{collection}/#{Integer(id)}.json").fetch(entity)
      end

      # Required references must have an explicit positive destination ID. An
      # empty selection is not an implicit ignore or a name-based match.
      def map(mappings, kind, source_id)
        value = mappings.fetch(kind, {}).fetch(source_id.to_s) do
          raise Error, "Missing #{kind} mapping for source ID #{source_id}"
        end
        id = Integer(value)
        raise Error, "Invalid #{kind} mapping" unless id.positive?
        id
      rescue ArgumentError, TypeError
        raise Error, "Invalid #{kind} mapping"
      end

      def destination_attributes(record)
        fields.each_with_object({}) { |field, result| result[field] = record[field] }
      end

      # Mirror mode, for an object the source no longer lists: "deleted" when the source
      # answers 404 for it, "moved" when it now belongs to another source project,
      # "hidden" when the source refuses to show it, else "present".
      def remote_state(client, path, source_project_id: nil)
        record = client.get(path)
        return "present" unless source_project_id
        project = record.values.first.is_a?(Hash) ? record.values.first["project"] : nil
        project && project["id"].to_i != source_project_id.to_i ? "moved" : "present"
      rescue Error => error
        return "deleted" if error.message.include?("HTTP 404")
        return "hidden" if error.message.include?("HTTP 403")
        raise
      end
    end

  end
end
