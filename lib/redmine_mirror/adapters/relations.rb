# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/relations.rb
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
# Resolve relation endpoints after issue creation and track missing cross-project targets.

module RedmineMirror
  module Adapters
    class Relations < IssueChildren
      def key; "issue_relations"; end
      def association; "relations"; end
      def configuration_options(input, _project)
        value = input.fetch("missing_target", "ignore")
        raise Error, "Invalid missing relation target policy" unless %w[ignore note].include?(value)
        { "missing_target" => value }
      end

      # Both endpoints can expose the same relation. Deduplicate by remote relation
      # ID within this pass; never confuse relation IDs with issue IDs.
      def records(client, project_id)
        seen = {}
        children = Enumerator.new do |output|
          Issues.new.records(client, project_id).each do |issue|
            next unless issue.fetch("project").fetch("id").to_i == project_id.to_i
            issue_detail(client, issue.fetch("id"), "relations").fetch("relations", []).each do |relation|
              output << relation.merge("project" => issue.fetch("project"), "owner_issue_id" => issue.fetch("id"))
            end
          end
        end
        children.lazy.reject { |record| seen[record.fetch("id")] }.map do |record|
          seen[record.fetch("id")] = true
          record
        end
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:, options: {}, track_blocks: false)
        policy = configuration_options(options, nil).fetch("missing_target")
        owner_id = lookup.call("issue_tracking", record.fetch("owner_issue_id", record.fetch("issue_id")))
        owner = Issue.find_by(id: owner_id, project_id: project_id) unless owner_id.to_s.start_with?("planned:")
        raise Error, "Missing owning issue correspondence" if apply && !owner
        endpoints = %w[issue_id issue_to_id].map do |field|
          source_id = record.fetch(field)
          local_issue_id = lookup.call("issue_tracking", source_id)
          local_issue_id || store.resolve_issue(source_id)
        end
        relation_attributes = { "issue_from_id" => endpoints[0], "issue_to_id" => endpoints[1],
          "relation_type" => record.fetch("relation_type"), "delay" => record["delay"] }
        event = { module: key, source_id: record.fetch("id"), destination_id: nil, action: "create" }
        # Missing projects do not prevent importing their owning issue. Track the
        # unresolved endpoint and optionally add one private explanatory note.
        if endpoints.any?(&:nil?)
          event[:action] = policy == "note" ? "note" : "ignored"
          event[:reason] = "Remote endpoint not synchronized"
          if policy == "note"
            note_key = "issue_relation_notes"
            previous = store.find(note_key, record.fetch("id"))
            if previous
              note_id = previous.fetch("destination_id")
              raise Error, "Source relation note modified; manual resolution required" unless digest(record) == previous.fetch("source_fingerprint")
              journal = owner&.journals&.find(previous.fetch("destination_id"))
              raise Error, "Local relation note modified" if journal && digest([journal.notes, journal.private_notes]) != previous.fetch("destination_fingerprint")
              event[:action] = "unchanged"
            elsif apply
              missing_source_issue_id = endpoints[0].nil? ? record.fetch("issue_id") : record.fetch("issue_to_id")
              setting = MirrorProjectSetting.find_by!(project_id: project_id)
              base_url = setting.source_url.sub(%r{/+\z}, '')
              base_url = "http://localhost:3101" if ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && %w[source gateway].include?(URI.parse(base_url).host)
              url = "#{base_url}/issues/#{Integer(missing_source_issue_id)}"
              text = "Mirror: remote relation ##{record.fetch('id')} (#{record.fetch('relation_type')}, delay: #{record['delay'].inspect}) could not be imported. Remote issue: #{url}"
              MirrorMapping.transaction do
                journal = owner.journals.new(user: User.anonymous, notes: text, private_notes: true)
                journal.notify = false
                journal.save!
                note_id = journal.id
                store.save(note_key, record.fetch("id"), "destination_id" => journal.id,
                  "source_fingerprint" => digest(record), "destination_fingerprint" => digest([text, true]))
              end
            end
          end
          if apply
            missing_source_issue_id = endpoints[0].nil? ? record.fetch("issue_id") : record.fetch("issue_to_id")
            store.pending_relation(record, local_issue_id: owner.id, remote_issue_id: missing_source_issue_id,
              status: "pending", reason: event.fetch(:reason), note_id: defined?(note_id) ? note_id : nil)
          end
          return event
        end
        # Planned IDs represent demands that will exist after the first pass.
        return event if endpoints.any? { |id| id.to_s.start_with?("planned:") }
        # Reuse a relation imported from its other endpoint instead of duplicating
        # it when independently synchronized projects are eventually both available.
        row = store.find(key, record.fetch("id")) || store.find_related_mapping(key, record.fetch("id"))
        if row
          relation = IssueRelation.find_by(id: row.fetch("destination_id"))
          raise Error, "Destination relation missing" unless relation
          raise Error, "Local relation modified" unless digest(relation.attributes.slice(*relation_attributes.keys)) == row.fetch("destination_fingerprint")
          raise Error, "Source relation modified; manual resolution required" unless digest(relation_attributes) == row.fetch("source_fingerprint")
          if apply && !store.find(key, record.fetch("id"))
            store.save(key, record.fetch("id"), "destination_id" => relation.id,
              "source_fingerprint" => digest(relation_attributes), "destination_fingerprint" => digest(relation.attributes.slice(*relation_attributes.keys)))
          end
          store.resolve_pending_relation(record.fetch("id")) if apply
          return event.merge(destination_id: relation.id, action: "unchanged")
        end
        relation = IssueRelation.new(relation_attributes)
        raise Error, "Destination rejected relation: #{relation.errors.full_messages.join(', ')}" unless relation.valid?
        if apply
          MirrorMapping.transaction do
            relation.save!
            store.save(key, record.fetch("id"), "destination_id" => relation.id,
              "source_fingerprint" => digest(relation_attributes), "destination_fingerprint" => digest(relation.attributes.slice(*relation_attributes.keys)))
          end
          event[:destination_id] = relation.id
          store.resolve_pending_relation(record.fetch("id"))
        end
        event
      rescue RedmineMirror::Error => error
        if (apply || track_blocks) && owner
          other_id = record.fetch("issue_id") == record.fetch("owner_issue_id", record.fetch("issue_id")) ? record.fetch("issue_to_id") : record.fetch("issue_id")
          store.pending_relation(record, local_issue_id: owner.id, remote_issue_id: other_id,
            status: "blocked", reason: error.message)
        end
        raise
      end
    end
  end
end
