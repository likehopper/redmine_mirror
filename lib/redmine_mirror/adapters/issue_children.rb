# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/issue_children.rb
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
# Import historical children once using native models and immutable-history fingerprints.

module RedmineMirror
  module Adapters
    # Historical objects require native destination models to retain their dates.
    class IssueChildren < Base
      def dependencies; %w[users issue_tracking]; end
      def referenced_users(record); [record["user"] || record["author"]].compact; end

      def records(client, project_id)
        Enumerator.new do |output|
          Issues.new.records(client, project_id).each do |issue|
            next unless issue.fetch("project").fetch("id").to_i == project_id.to_i
            detailed = issue_detail(client, issue.fetch("id"), association)
            detailed.fetch(association, []).each do |child|
              output << child.merge("project" => issue.fetch("project"), "issue_id" => issue.fetch("id"))
            end
          end
        end
      end

      # History is append-only here: both local edits and changed remote history
      # require manual resolution. Native writes and their mappings share a transaction.
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        raise Error, "Historical adapters require a local Redmine destination" unless defined?(Issue) && defined?(MirrorMapping)
        issue_id = lookup.call("issue_tracking", record.fetch("issue_id"))
        issue = Issue.where(project_id: project_id).find_by(id: issue_id) unless issue_id.to_s.start_with?("planned:")
        raise Error, "Missing destination issue correspondence" if apply && !issue
        attributes = imported_attributes(record, mappings, **(is_a?(Journals) ? { lookup: lookup, project: Project.find(project_id) } : {}))
        if respond_to?(:skip_reason) && (reason = skip_reason(attributes))
          return { module: key, source_id: record.fetch("id"), action: "ignored", reason: reason }
        end
        fingerprint = digest(attributes)
        mapping = store.find(key, record.fetch("id"))
        action = "create"
        if mapping
          target = find_target(mapping.fetch("destination_id"), issue)
          raise Error, "Local modification detected for #{key} source ID #{record.fetch('id')}" unless digest(local_attributes(target)) == mapping.fetch("destination_fingerprint")
          raise Error, "Modified source history requires manual resolution for #{key} source ID #{record.fetch('id')}" unless fingerprint == mapping.fetch("source_fingerprint")
          action = "unchanged"
        end
        target_id = mapping && mapping.fetch("destination_id")
        if apply && !mapping
          MirrorMapping.transaction do
            target = import(record, attributes, issue, source)
            target_id = target.id
            store.save(key, record.fetch("id"), "destination_id" => target_id,
              "source_fingerprint" => fingerprint, "destination_fingerprint" => digest(local_attributes(target)))
          end
        end
        { module: key, source_id: record.fetch("id"), destination_id: target_id, action: action }
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end
      def author_id(record, mappings)
        reference = record["user"] || record.fetch("author")
        Users.new.resolve(mappings, reference.fetch("id")) || User.anonymous.id
      end
    end
  end
end
