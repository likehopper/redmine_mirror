# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/files.rb
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
# Import the project's files (Files module) with their version, author, date and downloads.

require "time"

module RedmineMirror
  module Adapters
    # The Files module lists files attached to the project or to one of its versions
    # (GET projects/:id/files.json, View files). A file whose version has no local
    # correspondence yet waits for the next run instead of landing on the project.
    class Files < Base
      def key; "project_files"; end
      def project_module; :files; end
      def phase; :history; end
      def dependencies; %w[users project_versions]; end
      def referenced_users(record); [record["author"]].compact; end
      def catalog_statistics(record); { "bytes" => record["filesize"].to_i }; end

      def records(client, project_id)
        # Listed by version and file name: imported in source ID order instead.
        client.get("projects/#{Integer(project_id)}/files.json").fetch("files").sort_by { |row| row.fetch("id") }
          .map { |row| { "project" => { "id" => Integer(project_id) } }.merge(row) }
      rescue Error => error
        raise unless error.message.match?(/HTTP 40[13]/)
        raise Error, "The source project does not list its files: enable the Files module on the source project and give the source API key View files; #{error.message}"
      end

      def local_path(id, _project)
        "/attachments/#{Integer(id)}"
      end

      def remote_path(id, _setting)
        "attachments/#{Integer(id)}"
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        raise Error, "Enable the Files module on the destination project" unless project.module_enabled?(:files)
        filename = record.fetch("filename")
        mapping = store.find(key, record.fetch("id"))
        source_version = record["version"]
        version_id = source_version && lookup.call("project_versions", source_version.fetch("id"))
        if source_version && !version_id
          return { module: key, source_id: record.fetch("id"), destination_id: mapping&.fetch("destination_id"), action: "ignored",
            reason: "Version \"#{source_version['name']}\" (source ID #{source_version.fetch('id')}) not imported yet: the file waits for the next run" }
        end
        # A planned version exists only in the preview.
        version = apply || !version_id.to_s.start_with?("planned:") ? version_id && project.versions.find_by(id: version_id) : nil
        if version_id && !version && apply
          raise Error, "Version \"#{source_version['name']}\" of file #{filename} is mapped to a version of another destination project"
        end
        # Every file author is checked first, in the preview as well.
        attributes = Attachments.new.imported_attributes(record, mappings)
        source_fingerprint = digest(attributes.merge("version_id" => source_version&.fetch("id")))
        attachment = mapping && Attachment.find_by(id: mapping.fetch("destination_id"))
        attachment = nil if attachment && attachment.project != project
        action = "create"
        if mapping && !attachment
          # Deleted locally: a conflict, or recreated when the source wins.
          Policy.local_change!("Local modification detected for file #{filename}: the file was deleted")
          TextFormat.note("recreated")
        elsif attachment
          local_changed = digest(local_state(attachment)) != mapping.fetch("destination_fingerprint")
          if local_changed
            Policy.local_change!("Local modification detected for file #{filename}")
            TextFormat.note("local_overwritten")
          end
          action = local_changed || source_fingerprint != mapping.fetch("source_fingerprint") ? "update" : "unchanged"
        end
        event = { module: key, source_id: record.fetch("id"), destination_id: attachment&.id, action: action }
        return event unless apply && action != "unchanged"
        container = version || project
        MirrorMapping.transaction do
          if attachment
            # A source file is never replaced, only described or moved: update in place.
            attachment.update_columns(attributes.except("filesize", "created_on").merge(
              "container_type" => container.class.name, "container_id" => container.id, "created_on" => Time.iso8601(attributes.fetch("created_on"))))
          else
            attachment = Attachments.new.import(record, attributes, container, source)
            # Not writable through the API: the source download count is copied once.
            attachment.update_columns(downloads: Integer(record.fetch("downloads", 0)))
          end
          attachment.reload
          store.save(key, record.fetch("id"), "destination_id" => attachment.id,
            "source_fingerprint" => source_fingerprint, "destination_fingerprint" => digest(local_state(attachment)))
        end
        event.merge(destination_id: attachment.id)
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "attachments/#{Integer(source_id)}.json")
      end

      def delete_local(destination_id, project_id)
        Attachments.new.delete_local(destination_id, project_id)
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      # Local downloads are not a modification.
      def local_state(attachment)
        Attachments.new.local_attributes(attachment).merge("container" => [attachment.container_type, attachment.container_id])
      end
    end
  end
end
