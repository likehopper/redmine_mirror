# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/runner.rb
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
# Plan and apply dependency-ordered imports while guarding managed destination fields.

module RedmineMirror
  class Runner
    def initialize(source:, destination:, store:, registry: REGISTRY)
      @source_client, @destination_client, @mapping_store, @adapter_registry = source, destination, store, registry
    end

    # Preview and apply use the same transformations and conflict guards. A preview
    # may persist a conflict diagnostic, but it never writes imported Redmine objects.
    def run(config, apply: false, track_relation_blocks: false, &block)
      # Texts are converted to the destination format for the whole run (TextFormat).
      # The source wins in mirror mode (Policy), for every adapter of the run.
      Policy.with(source_wins: config["source_wins"]) do
        TextFormat.with(config["text_format"]) { run_modules(config, apply: apply, track_relation_blocks: track_relation_blocks, &block) }
      end
    end

    def run_modules(config, apply: false, track_relation_blocks: false)
      source_project_id = Integer(config.fetch("source_project_id"))
      destination_project_id = Integer(config.fetch("destination_project_id"))
      raise Error, "Project IDs must be positive" unless source_project_id.positive? && destination_project_id.positive?
      adapters = @adapter_registry.resolve(config.fetch("modules"))
      raise Error, "Select at least one module" if adapters.empty?
      if adapters.any? { |adapter| adapter.respond_to?(:synchronize) }
        local_url = ENV["MIRROR_DESTINATION_URL"].to_s.sub(%r{/+\z}, "")
        requested_url = config["destination_url"].to_s.sub(%r{/+\z}, "")
        raise Error, "Historical adapters require the configured local destination and database store" unless !local_url.empty? && local_url == requested_url && @mapping_store.is_a?(DatabaseStore)
      end
      @source_client.get("projects/#{source_project_id}.json")
      @destination_client.get("projects/#{destination_project_id}.json")
      planned_correspondences = {}
      results = []
      # A planned correspondence lets later adapters validate a first import. Shared
      # versions may already belong to a separately synchronized source project.
      lookup = lambda do |key, id|
        mapping = @mapping_store.find(key, id)
        result = mapping ? mapping.fetch("destination_id") : planned_correspondences[[key, id]]
        if !result && key == "project_versions" && @mapping_store.respond_to?(:find_related_mapping)
          shared = @mapping_store.find_related_mapping(key, id)
          result = shared && shared.fetch("destination_id")
        end
        result
      end
      # Texts rewrite their issue references through the same correspondences.
      TextFormat.lookup = lookup
      # One source record through its adapter. A record whose texts cite issues not
      # imported yet is processed again at the end of an applying run (deferred).
      deferred = []
      # Source issues left out by an ignored tracker or status, with that table key. Their
      # records in later modules (history, time, watchers, relations...) are ignored with
      # them, not errors.
      ignored_issues = {}
      process = lambda do |adapter, record|
        TextFormat.reset_flags
        if @mapping_store.respond_to?(:excluded?) && @mapping_store.excluded?(adapter.key, record.fetch("id"))
          event = { module: adapter.key, source_id: record.fetch("id"), destination_id: @mapping_store.find(adapter.key, record.fetch("id"))&.fetch("destination_id"), action: "ignored", reason: "Local object retained by project conflict resolution" }
          results << event
          yield event if block_given?
          next
        end
        reason = nil
        if adapter.respond_to?(:ignored_reference) && (kind = adapter.ignored_reference(record, config.fetch("mappings", {})))
          ignored_issues[record.fetch("id")] = kind if adapter.is_a?(Adapters::Issues)
          reason = "#{kind.tr('_', ' ').capitalize} ignored by the mapping"
        elsif !ignored_issues.empty? && adapter.respond_to?(:source_issue_ids) && (issue_id = adapter.source_issue_ids(record).find { |id| ignored_issues[id] })
          reason = "Issue ##{issue_id} not imported: its #{ignored_issues[issue_id]} is ignored by the mapping"
        end
        if reason
          # A relation or parent link once waiting for this issue no longer waits.
          if apply
            @mapping_store.resolve_pending_relation(record.fetch("id")) if adapter.is_a?(Adapters::Relations) && @mapping_store.respond_to?(:resolve_pending_relation)
            @mapping_store.resolve_pending_parent(record.fetch("id")) if adapter.is_a?(Adapters::Hierarchy) && @mapping_store.respond_to?(:resolve_pending_parent)
          end
          event = { module: adapter.key, source_id: record.fetch("id"), destination_id: @mapping_store.find(adapter.key, record.fetch("id"))&.fetch("destination_id"), action: "ignored", reason: reason }
          results << event
          yield event if block_given?
          next
        end
        begin
          # Native adapters own their validation and transactions; REST adapters
          # below use the generic payload/read/fingerprint import path.
          if adapter.respond_to?(:synchronize)
            event = adapter.synchronize(record, project_id: destination_project_id,
              mappings: config.fetch("mappings", {}), lookup: lookup,
              store: @mapping_store, source: @source_client, apply: apply, **(adapter.is_a?(Adapters::Relations) ? { options: config.fetch("module_options", {}).fetch(adapter.key, {}), track_blocks: track_relation_blocks } : (adapter.is_a?(Adapters::Hierarchy) ? { track_blocks: track_relation_blocks } : {})))
            planned_correspondences[[adapter.key, record.fetch("id")]] = "planned:#{record.fetch('id')}" if !apply && !event[:destination_id] && adapter.is_a?(Adapters::ProjectReferences)
            @mapping_store.resolve_conflict(adapter.key, record.fetch("id")) if apply && @mapping_store.respond_to?(:resolve_conflict)
            flag(event)
            results << event
            yield event if block_given?
            next
          end
          id = record.fetch("id")
          payload = adapter.payload(record, destination_project_id, config.fetch("mappings", {}), lookup, options: config.fetch("module_options", {}).fetch(adapter.key, {}).merge(config.fetch("module_options", {}).fetch("users", {})))
          if adapter.is_a?(Adapters::Issues) && adapters.any? { |entry| entry.is_a?(Adapters::CustomFields) }
            values = Adapters::CustomFields.new.imported_values(record, project_id: destination_project_id,
              mappings: config.fetch("mappings", {}), lookup: lookup)
            payload["custom_fields"] = values.map { |custom_field_id, value| { "id" => Integer(custom_field_id), "value" => value } }
          end
          if adapter.is_a?(Adapters::Issues) && payload.keys.any? { |field| %w[created_on updated_on closed_on].include?(field) }
            local_url = ENV["MIRROR_DESTINATION_URL"].to_s.sub(%r{/+\z}, "")
            raise Error, "Preserving issue metadata requires the configured local destination" unless @mapping_store.is_a?(DatabaseStore) && !local_url.empty? && config["destination_url"].to_s.sub(%r{/+\z}, "") == local_url
          end
          # References the REST API refuses (locked users, closed versions) are written
          # locally after the API call; only a local destination can restore them.
          rest_payload = adapter.respond_to?(:rest_attributes) && @mapping_store.is_a?(DatabaseStore) ? adapter.rest_attributes(payload) : payload
          if rest_payload != payload
            local_url = ENV["MIRROR_DESTINATION_URL"].to_s.sub(%r{/+\z}, "")
            raise Error, "Locked users and closed versions require the configured local destination" unless !local_url.empty? && config["destination_url"].to_s.sub(%r{/+\z}, "") == local_url
          end
          mapping = @mapping_store.find(adapter.key, id)
          action = "create"
          if mapping
            current = begin
              adapter.read(@destination_client, mapping.fetch("destination_id"))
            rescue Error => error
              raise unless error.message.include?("HTTP 404")
              nil
            end
            if current.nil?
              # Deleted locally: a conflict, or recreated when the source wins.
              Policy.local_change!("Local modification detected for #{adapter.key} source ID #{id}: the destination object was deleted")
              TextFormat.note("recreated")
              mapping = nil
            else
              local_changed = current.fetch("project").fetch("id").to_i != destination_project_id
              Policy.local_change!("Destination record moved to another project") if local_changed
              fingerprint = digest(adapter.destination_attributes(current))
              # Existing issue mappings predate metadata tracking; validate their old fields first.
              legacy_fingerprint = adapter.is_a?(Adapters::Issues) ? digest(adapter.destination_attributes(current).reject { |field, _| (Adapters::Issues::METADATA_FIELDS + %w[category_id fixed_version_id]).include?(field) }) : nil
              reference_legacy = adapter.is_a?(Adapters::Issues) ? digest(adapter.destination_attributes(current).reject { |field, _| %w[category_id fixed_version_id].include?(field) }) : nil
              unless [fingerprint, legacy_fingerprint, reference_legacy].compact.include?(mapping.fetch("destination_fingerprint"))
                Policy.local_change!("Local modification detected for #{adapter.key} source ID #{id}")
                local_changed = true
              end
              TextFormat.note("local_overwritten") if local_changed
              action = !local_changed && mapping.fetch("source_fingerprint") == digest(payload) ? "unchanged" : "update"
            end
          end
          # API writes and correspondence persistence are not one transaction.
          # A lost response must be inspected before retrying a creation.
          if apply && action != "unchanged"
            if mapping
              # Custom field updates retain their own conflict checks and native validation.
              @destination_client.update("#{adapter.collection}/#{mapping.fetch('destination_id')}.json", adapter.entity => rest_payload.except("custom_fields"))
              destination_record_id = mapping.fetch("destination_id")
            else
              created = @destination_client.create("#{adapter.collection}.json", adapter.entity => rest_payload)
              destination_record_id = created.fetch(adapter.entity).fetch("id")
            end
            adapter.restore_metadata(payload, destination_record_id, destination_project_id) if adapter.respond_to?(:restore_metadata) && @mapping_store.is_a?(DatabaseStore)
            current = adapter.read(@destination_client, destination_record_id)
            @mapping_store.save(adapter.key, id, { "destination_id" => destination_record_id,
              "source_fingerprint" => digest(payload),
              "destination_fingerprint" => digest(adapter.destination_attributes(current)) })
          end
          planned_correspondences[[adapter.key, id]] = "planned:#{id}" unless mapping || apply
          event = flag({ module: adapter.key, source_id: id, destination_id: (apply && action != "unchanged" ? destination_record_id : mapping && mapping["destination_id"]), action: action })
          results << event
          yield event if block_given?
          @mapping_store.resolve_conflict(adapter.key, record.fetch("id")) if apply && @mapping_store.respond_to?(:resolve_conflict)
        # Keep the first actionable divergence and stop; remaining records are
        # deliberately left unprocessed rather than reported as successful.
        rescue Error => error
          @mapping_store.record_conflict(adapter.key, record.fetch("id"), error) if @mapping_store.respond_to?(:record_conflict)
          # on_error "stop" (default) ends the run at the first object error; "collect"
          # and "skip" record it and go on. Objects that depend on this one then fail
          # on their missing correspondence and are reported as well.
          raise unless %w[collect skip].include?(config["on_error"])
          event = { module: adapter.key, source_id: record.fetch("id"), action: "error" }.merge(error_fields(error))
          results << event
          yield event if block_given?
        end
      end
      seen = {}
      adapters.each do |adapter|
        seen_source_ids = seen[adapter.key] = []
        adapter.records(@source_client, source_project_id).each do |record|
          # APIs may include descendants; never import another project's records.
          next unless record.fetch("project").fetch("id").to_i == source_project_id
          seen_source_ids << record.fetch("id")
          before = results.size
          process.call(adapter, record)
          unresolved = results.drop(before).any? { |event| Array(event[:flags]).include?("issue_references_unresolved") }
          deferred << [adapter, record] if apply && unresolved
        end
        @mapping_store.prune_pending_parents(seen_source_ids) if apply && adapter.is_a?(Adapters::Hierarchy) && @mapping_store.respond_to?(:prune_pending_parents)
        @mapping_store.prune_pending_relations(seen_source_ids) if apply && adapter.is_a?(Adapters::Relations)
      end
      # The cited issues are imported now: rewrite those references to local numbers.
      deferred.each { |adapter, record| process.call(adapter, record) }
      if config["source_wins"] && @mapping_store.respond_to?(:mappings)
        propagate_deletions(adapters, seen, config, source_project_id, destination_project_id, apply) do |event|
          results << event
          yield event if block_given?
        end
      end
      results
    end

    # Share of a module's objects a run may delete without an explicit confirmation.
    DELETION_LIMIT = 0.1

    # Mirror mode: an object imported earlier and no longer listed by the source is
    # deleted locally only when the source confirms it for that very object (HTTP 404),
    # never because a list missed it. Children come before their parents. Beyond the
    # limit, nothing is deleted until a run confirms the deletions.
    def propagate_deletions(adapters, seen, config, source_project_id, project_id, apply)
      plans = adapters.reverse.filter_map do |adapter|
        next unless adapter.respond_to?(:source_state)
        known = @mapping_store.mappings(adapter.key)
        listed = seen.fetch(adapter.key, [])
        candidates = known.reject { |source_id, _| listed.include?(source_id) }.filter_map do |source_id, destination_id|
          state = adapter.source_state(@source_client, source_id, destination_id, source_project_id: source_project_id, project_id: project_id)
          next [source_id, destination_id] if state == "deleted"
          yield({ module: adapter.key, source_id: source_id, destination_id: destination_id, action: "ignored", reason: "Not listed by the source but #{state}; kept" })
          nil
        rescue Error => error
          raise unless %w[collect skip].include?(config["on_error"])
          yield({ module: adapter.key, source_id: source_id, destination_id: destination_id, action: "error" }.merge(error_fields(error)))
          nil
        end
        [adapter, candidates, [(known.size * DELETION_LIMIT).floor, 2].max]
      end
      blocked = !config["confirm_deletions"] && plans.any? { |_, candidates, limit| candidates.size > limit }
      plans.each do |adapter, candidates, limit|
        candidates.each do |source_id, destination_id|
          event = { module: adapter.key, source_id: source_id, destination_id: destination_id, action: "delete" }
          if blocked
            yield event.merge(action: "error", reason: "Deletion awaits confirmation: #{candidates.size} #{adapter.key} object(s) deleted on the source, more than the limit of #{limit}")
            next
          end
          begin
            if apply
              transaction do
                adapter.delete_local(destination_id, project_id)
                @mapping_store.delete(adapter.key, source_id)
              end
            end
            yield event
          rescue Error => error
            raise unless %w[collect skip].include?(config["on_error"])
            yield event.merge(action: "error").merge(error_fields(error))
          end
        end
      end
    end

    private

    # The reason, and the details the run log uses to explain the fix. A version that the
    # project does not own is looked up once per run: its owner tells which project to
    # synchronize first.
    def error_fields(error)
      details = error.details
      return { reason: error.message } unless details
      if details["code"] == "missing_reference" && details["field"] == "fixed_version"
        @version_owners ||= {}
        owner = @version_owners.fetch(details["id"]) do
          @version_owners[details["id"]] = begin
            @source_client.get("versions/#{Integer(details['id'])}.json").fetch("version")["project"]
          rescue Error, KeyError, ArgumentError
            nil
          end
        end
        details = details.merge("owner_id" => owner["id"].to_s, "owner_name" => owner["name"].to_s) if owner.is_a?(Hash)
      end
      { reason: error.message, details: details }
    end

    # A local deletion and its correspondence go together; outside Redmine (standalone
    # tests) there is no database transaction.
    def transaction(&block)
      defined?(::MirrorMapping) ? ::MirrorMapping.transaction(&block) : yield
    end

    # Attach the special cases met while processing the record (execution log review).
    def flag(event)
      flags = TextFormat.flags
      event[:flags] = flags unless flags.empty?
      warnings = TextFormat.warnings
      event[:warnings] = warnings unless warnings.empty?
      event
    end

    # Stable top-level field ordering makes fingerprints independent of hash insertion order.
    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(value.sort.to_h))
    end
  end
end
