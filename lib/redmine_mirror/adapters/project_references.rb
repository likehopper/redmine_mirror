# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/project_references.rb
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
# Create categories and versions before issues while preserving separate source identities.

require "time"
module RedmineMirror
  module Adapters
    class ProjectReferences < Base
      def dependencies; ["users"]; end
      def phase; :references; end
      def records(client, project_id)
        client.get("projects/#{Integer(project_id)}/#{collection}.json").fetch(collection).map { |row| { "project" => { "id" => project_id } }.merge(row) }
      end
      # Match only through persisted IDs, never by name. Native uniqueness and
      # sharing validations determine whether a new category or version is acceptable.
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        imported_attributes = attributes(record, mappings)
        row = store.find(key, record.fetch("id"))
        target = row && model.find_by(project_id: project.id, id: row.fetch("destination_id"))
        if row && !target
          # Deleted locally: a conflict, or recreated when the source wins.
          Policy.local_change!("Local modification detected for #{key} source ID #{record.fetch('id')}: the destination object was moved or deleted")
          TextFormat.note("recreated")
          row = nil
        end
        local_changed = target && digest(local_attributes(target)) != row.fetch("destination_fingerprint")
        if local_changed
          Policy.local_change!("Local modification detected for #{key} source ID #{record.fetch('id')}")
          TextFormat.note("local_overwritten")
        end
        action = row ? (!local_changed && digest(imported_attributes) == row.fetch("source_fingerprint") ? "unchanged" : "update") : "create"
        if action != "unchanged"
          candidate = target || model.new(project: project)
          candidate.assign_attributes(imported_attributes)
          raise Error, "Destination rejected #{key}: #{candidate.errors.full_messages.join(', ')}" unless candidate.valid?
        end
        if apply && action != "unchanged"
          MirrorMapping.transaction do
            target ||= model.new(project: project)
            target.assign_attributes(imported_attributes)
            raise Error, "Destination rejected #{key}: #{target.errors.full_messages.join(', ')}" unless target.valid?
            target.save!
            store.save(key, record.fetch("id"), "destination_id" => target.id,
              "source_fingerprint" => digest(imported_attributes), "destination_fingerprint" => digest(local_attributes(target)))
          end
        end
        { module: key, source_id: record.fetch("id"), destination_id: target&.id, action: action }
      end
      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end
      def local_attributes(record); record.attributes.slice(*fields); end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "#{collection}/#{Integer(source_id)}.json")
      end

      def delete_local(destination_id, project_id)
        model.where(project_id: project_id).find_by(id: destination_id)&.destroy
      end
    end
    class Categories < ProjectReferences
      def key; "issue_categories"; end
      def collection; "issue_categories"; end
      def model; IssueCategory; end
      def fields; %w[name assigned_to_id]; end
      def referenced_users(record); [record["assigned_to"]].compact; end

      # The project's own categories, plus those its issues use: an issue can keep a
      # category of another source project (moved issues, plugins). Those are created in
      # the destination project under the same name. Listing categories requires "Manage
      # issue categories" on the source; without it, only the used ones are known, and
      # without their default assignee.
      def records(client, project_id)
        listed = begin
          super
        rescue Error => error
          raise unless error.message.start_with?("Redmine API returned HTTP 403")
          []
        end
        known = listed.map { |category| category.fetch("id") }
        used = Issues.new.records(client, project_id).filter_map { |issue| issue["category"] }
          .uniq { |category| category.fetch("id") }.reject { |category| known.include?(category.fetch("id")) }
        listed + used.map { |category| { "project" => { "id" => project_id }, "id" => category.fetch("id"), "name" => category.fetch("name") } }
      end
      def attributes(record, mappings)
        { "name" => record.fetch("name"), "assigned_to_id" => record["assigned_to"] ? Users.new.resolve(mappings, record["assigned_to"].fetch("id")) : nil }
      end
    end
    class Versions < ProjectReferences
      def key; "project_versions"; end
      def collection; "versions"; end
      def model; ::Version; end
      def fields; %w[name description status effective_date sharing]; end
      def attributes(record, _mappings)
        { "name" => record.fetch("name"), "description" => record["description"].to_s,
          "status" => record.fetch("status"), "effective_date" => record["due_date"], "sharing" => record.fetch("sharing", "none") }
      end
      def records(client, project_id)
        super.select { |record| record.fetch("project").fetch("id").to_i == project_id.to_i }
      end
      def local_attributes(record)
        super.merge("effective_date" => record.effective_date&.iso8601)
      end

      # Redmine refuses to delete a version that issues still use.
      def delete_local(destination_id, project_id)
        version = model.where(project_id: project_id).find_by(id: destination_id)
        return unless version
        raise Error, "Version \"#{version.name}\" deleted on the source is still used locally; it was kept" unless version.deletable?
        version.destroy
      end
    end
  end
end
