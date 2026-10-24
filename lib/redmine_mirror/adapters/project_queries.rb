# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/project_queries.rb
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
# Recreate the project's saved queries (issues, time entries, agile boards) with their
# filters, columns, sorts and options translated through the mappings.

module RedmineMirror
  module Adapters
    # The API lists only query names: the source must run Mirror and share its queries
    # (Mirror source). A query whose filters cannot all be translated is not created, so
    # that no query shows other issues than its name promises; columns, sorts and groups
    # that do not exist here are left out.
    class ProjectQueries < Base
      SOURCE_VERSION = "1.0.0-beta.31"
      REFUSALS = {
        "disabled" => "Mirror source is disabled on the source Redmine: its administrator must allow it (Administration → Plugins → Redmine Mirror)",
        "module" => "Enable the Mirror source module on the source project",
        "not_shared" => "Share Saved queries in the source project's Settings → Mirror source",
        "permission" => "The source API key needs View issues in the source project"
      }.freeze
      # Filter values that are references, by filter: mapping tables, then correspondences.
      MAPPED = { "status_id" => "status", "tracker_id" => "tracker", "priority_id" => "priority", "activity_id" => "activity",
        "assigned_to_role" => "role", "member_of_group" => "group" }.freeze
      LOOKED_UP = { "fixed_version_id" => "project_versions", "category_id" => "issue_categories", "issue_id" => "issue_tracking",
        "parent_id" => "issue_tracking", "root_id" => "issue_tracking", "agile_sprints" => "agile_sprints" }.freeze
      USERS = %w[assigned_to_id author_id watcher_id user_id updated_by last_updated_by].freeze
      PROJECTS = %w[project_id subproject_id parent_project_id].freeze
      # Filters of the Scrum plugin and their redmine_agile equivalents.
      RENAMED = { "sprint_id" => "agile_sprints" }.freeze
      # Board options naming statuses or a sprint; the others are copied.
      UNTRANSLATABLE = Class.new(StandardError)

      def key; "project_queries"; end
      def project_module; :issue_tracking; end
      def phase; :history; end
      def dependencies; ["users"]; end
      def selection_hint; :text_mirror_project_queries_source_hint; end
      def referenced_users(record); [record["user"]].compact; end

      def records(client, project_id)
        client.get("projects/#{Integer(project_id)}/mirror/source/queries.json").fetch("queries")
          .map { |row| row.merge("project" => { "id" => Integer(project_id) }) }
      rescue Error => error
        reason = error.message[/\(Mirror source: ([a-z_]+)\)/, 1]
        raise Error, REFUSALS.fetch(reason) if REFUSALS.key?(reason)
        raise Error, "The source Redmine does not list saved queries: install Redmine Mirror #{SOURCE_VERSION} or later on it" if error.message.include?("HTTP 404")
        raise Error, REFUSALS.fetch("permission") if error.message.include?("HTTP 403") || error.message.include?("HTTP 401")
        raise
      end

      def local_path(id, project)
        query = ::Query.find_by(id: id)
        query && "/projects/#{project.identifier}/#{query.is_a?(::TimeEntryQuery) ? 'time_entries' : (query.type == 'AgileQuery' ? 'agile/board' : 'issues')}?query_id=#{query.id}"
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        name = record.fetch("name")
        event = { module: key, source_id: record.fetch("id"), destination_id: nil }
        klass = record.fetch("type").safe_constantize
        return event.merge(action: "ignored", reason: "#{record['type']} needs a plugin this Redmine does not have") unless klass && klass <= ::Query
        mapping = store.find(key, record.fetch("id"))
        query = mapping && klass.find_by(id: mapping.fetch("destination_id"), project_id: project.id)
        if mapping && !query
          Policy.local_change!("Local modification detected for query \"#{name}\": the query was deleted")
          TextFormat.note("recreated")
        elsif query && digest(local_state(query)) != mapping.fetch("destination_fingerprint")
          Policy.local_change!("Local modification detected for query \"#{name}\"")
          TextFormat.note("local_overwritten")
        end
        candidate = query || klass.new(project: project)
        begin
          attributes = as_administrator { translate(record, candidate, project, mappings, lookup) }
        rescue UNTRANSLATABLE => error
          return event.merge(action: "ignored", reason: "Query \"#{name}\" not imported: #{error.message}")
        end
        changed = query.nil? || local_state(query) != normalized(attributes)
        event.merge!(destination_id: query&.id, action: query ? (changed ? "update" : "unchanged") : "create")
        return event unless apply && changed
        MirrorMapping.transaction do
          query = write_query(candidate, attributes)
          store.save(key, record.fetch("id"), "destination_id" => query.id, "source_fingerprint" => digest(record.except("project")),
            "destination_fingerprint" => digest(local_state(query)))
        end
        event.merge(destination_id: query.id)
      end

      def write_query(query, attributes)
        query.assign_attributes(attributes.except("role_ids", "options", "filters"))
        query.filters = attributes.fetch("filters")
        query.options = (query.options || {}).merge(attributes.fetch("options").transform_keys(&:to_sym))
        query.role_ids = attributes.fetch("role_ids")
        raise Error, "Destination rejected query \"#{query.name}\": #{query.errors.full_messages.join(', ')}" unless query.save
        query
      end

      def local_state(query)
        { "name" => query.name, "user_id" => query.user_id, "visibility" => query.visibility,
          "filters" => plain(query.filters || {}), "column_names" => plain(query.read_attribute(:column_names) || []),
          "sort_criteria" => plain(query.read_attribute(:sort_criteria) || []), "group_by" => query.group_by.presence,
          "role_ids" => query.role_ids.sort, "options" => plain((query.options || {}).slice(*options_keys(query))) }
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      # Some filters exist only for a logged user ("me", watchers, roles).
      def as_administrator
        previous = User.current
        User.current = User.active.find_by(admin: true) || previous
        yield
      ensure
        User.current = previous
      end

      # The shape of local_state, to compare what would be written with what is there.
      def normalized(attributes)
        attributes.merge("filters" => plain(attributes.fetch("filters")), "column_names" => plain(attributes.fetch("column_names")),
          "sort_criteria" => plain(attributes.fetch("sort_criteria")), "role_ids" => attributes.fetch("role_ids").sort,
          "options" => plain(attributes.fetch("options")))
      end

      def plain(value)
        value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
        case value
        when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = plain(item) }.sort.to_h
        when Array then value.map { |item| plain(item) }
        when Symbol then value.to_s
        else value
        end
      end

      def options_keys(query)
        query.type == "AgileQuery" ? %i[f_status wp sprint_id sprints_enabled color_base default_chart chart_unit is_default backlog_column draw_relations hours_by_day totalable_names] : %i[totalable_names]
      end

      # Everything the destination query gets, or UNTRANSLATABLE with the reason.
      def translate(record, query, project, mappings, lookup)
        owner = record["user"] && Users.new.resolve(mappings, record["user"].fetch("id"))
        visibility = Integer(record.fetch("visibility"))
        raise UNTRANSLATABLE, "its private owner is anonymized" if visibility == ::Query::VISIBILITY_PRIVATE && !owner
        query.project = project
        filters = record.fetch("filters").each_with_object({}) do |(field, filter), result|
          field = RENAMED.fetch(field, field)
          raise UNTRANSLATABLE, "filter \"#{field}\" does not exist here" unless query.available_filters.key?(field)
          result[field] = { operator: filter.fetch("operator"), values: translate_values(field, filter.fetch("operator"), Array(filter["values"]), project, mappings, lookup) }
        end
        columns = Array(record["column_names"]).map { |name| translate_column(name.to_s, project, mappings) }.compact
        columns &= query.available_columns.map { |column| column.name.to_s }
        sort = Array(record["sort_criteria"]).map { |field, order| [translate_column(field.to_s, project, mappings), order] }
          .select { |field, _| field && query.sortable_columns.key?(field) }
        group_by = record["group_by"].presence && translate_column(record["group_by"], project, mappings)
        group_by = nil unless group_by && query.groupable_columns.map { |column| column.name.to_s }.include?(group_by)
        roles = visibility == ::Query::VISIBILITY_ROLES ? roles(record, project, mappings) : []
        { "name" => record.fetch("name"), "user_id" => owner || User.anonymous.id, "visibility" => visibility,
          "filters" => filters, "column_names" => columns, "sort_criteria" => sort, "group_by" => group_by,
          "role_ids" => roles, "options" => translate_options(record.fetch("options", {}), query, project, mappings, lookup) }
      end

      # Time entry queries name issue fields "issue.<field>".
      def translate_values(name, operator, values, project, mappings, lookup)
        # Operators without values ("none", "any", open/closed) send none or [""].
        return values if values.all? { |value| value.to_s.empty? }
        field = name.delete_prefix("issue.")
        if MAPPED.key?(field)
          values.map { |value| mapped(mappings, MAPPED.fetch(field), value, field) }
        elsif LOOKED_UP.key?(field)
          values.map do |value|
            local = Integer(value, exception: false) && lookup.call(LOOKED_UP.fetch(field), Integer(value))
            raise UNTRANSLATABLE, "value #{value} of filter \"#{field}\" has no correspondence here" unless local && !local.to_s.start_with?("planned:")
            local.to_s
          end
        elsif USERS.include?(field)
          values.map do |value|
            next value if value == "me"
            local = Users.new.resolve(mappings, value)
            raise UNTRANSLATABLE, "user #{value} of filter \"#{field}\" is anonymized" unless local
            local.to_s
          end
        elsif PROJECTS.include?(field)
          raise UNTRANSLATABLE, "filter \"#{field}\" names projects (operator #{operator})"
        elsif (source_id = field[/\Acf_(\d+)\z/, 1])
          custom_field_values(Integer(source_id), values, project, mappings, lookup)
        else
          values
        end
      rescue Error => error
        raise UNTRANSLATABLE, error.message
      end

      def mapped(mappings, kind, value, field)
        local = mappings.fetch(kind, {})[value.to_s]
        raise UNTRANSLATABLE, "#{kind} #{value} of filter \"#{field}\" is not mapped" unless local.to_s.match?(/\A\d+\z/)
        local.to_s
      end

      def custom_field_values(source_id, values, project, mappings, lookup)
        adapter = CustomFields.new
        raise UNTRANSLATABLE, "custom field ##{source_id} is not imported" if adapter.ignored?(source_id, mappings)
        field = adapter.target_field(source_id, mappings, project)
        setting = project.mirror_project_setting
        definition = setting&.source_catalog.to_h.fetch("custom_field_definitions", {}).fetch(source_id.to_s) { raise UNTRANSLATABLE, "refresh custom field references" }
        options = setting.module_options.fetch(adapter.key, {})
        # One filter value at a time, in the shape of a field value.
        values.flat_map do |value|
          Array(adapter.translate_value(field.multiple? ? [value] : value, source_id: source_id, field: field, definition: definition,
            options: options, mappings: mappings, lookup: lookup)).map(&:to_s)
        end
      end

      # Columns, sorts and groups: custom fields are renamed, Scrum names become agile ones.
      def translate_column(name, project, mappings)
        name = RENAMED.fetch(name, name)
        prefix, source_id = name.match(/\A((?:issue\.)?)cf_(\d+)\z/)&.captures
        return name unless source_id
        local = mappings.fetch("custom_field", {})[source_id]
        local.to_s.match?(/\A\d+\z/) ? "#{prefix}cf_#{local}" : nil
      end

      # Roles mapped in Members; without any, the roles that manage the project settings.
      def roles(record, project, mappings)
        mapped = record.fetch("roles", []).map { |role| mappings.fetch("role", {})[role.fetch("id").to_s] }
          .select { |id| id.to_s.match?(/\A\d+\z/) }.map(&:to_i)
        return mapped.uniq.sort if mapped.any?
        managers = project.members.flat_map(&:roles).uniq.select { |role| role.allowed_to?(:edit_project) }
        managers = Role.givable.select { |role| role.allowed_to?(:edit_project) } if managers.empty?
        raise UNTRANSLATABLE, "no role mapped and no role manages the project settings" if managers.empty?
        TextFormat.note("query_roles_fallback")
        managers.map(&:id).sort
      end

      def translate_options(options, query, project, mappings, lookup)
        options = options.to_h
        result = options.slice(*options_keys(query).map(&:to_s))
        if query.type == "AgileQuery"
          result["f_status"] = Array(options["f_status"]).map { |id| mapped(mappings, "status", id, "board columns") } if options.key?("f_status")
          if options["wp"].is_a?(Hash)
            result["wp"] = options["wp"].each_with_object({}) do |(id, limit), limits|
              local = mappings.fetch("status", {})[id.to_s]
              limits[local.to_s] = limit if local.to_s.match?(/\A\d+\z/)
            end
          end
          if options["sprint_id"].present?
            sprint = lookup.call("agile_sprints", Integer(options["sprint_id"]))
            result["sprint_id"] = sprint && !sprint.to_s.start_with?("planned:") ? sprint : nil
          end
        end
        result
      end
    end
  end
end
