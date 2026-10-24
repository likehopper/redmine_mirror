# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/documents.rb
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
# Import documents with their category, date and files through local models.

require "time"

module RedmineMirror
  module Adapters
    # Redmine has no documents REST API: the source must run Mirror and share its
    # documents (Mirror source, MirrorSourceApiController), files included.
    class Documents < Base
      SOURCE_VERSION = "1.0.0-beta.19"
      # Document files have their own correspondences, inside the Documents module.
      ATTACHMENTS = "document_attachments"

      def key; "documents"; end
      def project_module; :documents; end
      def phase; :history; end
      def dependencies; ["users"]; end
      def text_samples(record); [record["description"]]; end
      def mapping_tables; [MappingTable.new("document_category", reference_fields: ["category"])]; end
      def ignored_reference(record, mappings); "document_category" if ignored_mapping?(mappings, "document_category", record.dig("category", "id")); end

      def referenced_users(record)
        record.fetch("attachments", []).filter_map { |attachment| attachment["author"] }
      end

      def catalog_references(client, _project_id)
        { "document_category" => client.get("enumerations/document_categories.json").fetch("document_categories") }
      end

      # What the source must change, for each lock it names (Source.refusal).
      REFUSALS = {
        "disabled" => "Mirror source is disabled on the source Redmine: its administrator must allow it, and this data (Administration → Plugins → Redmine Mirror)",
        "module" => "Enable the Mirror source module on the source project",
        "not_shared" => "Share Documents in the source project's Settings → Mirror source",
        "permission" => "The source API key needs View documents in the source project"
      }.freeze

      # Shown next to the module in the connection form.
      def selection_hint; :text_mirror_documents_source_hint; end

      def records(client, project_id)
        client.get("projects/#{Integer(project_id)}/mirror/source/documents.json").fetch("documents")
      rescue Error => error
        raise Error, "The source Redmine does not list documents: install Redmine Mirror #{SOURCE_VERSION} or later on it" if error.message.include?("HTTP 404")
        reason = error.message[/\(Mirror source: ([a-z_]+)\)/, 1]
        raise Error, REFUSALS.fetch(reason, REFUSALS.fetch("permission")) if error.message.include?("HTTP 403") || error.message.include?("HTTP 401")
        raise
      end

      def local_path(id, _project)
        "/documents/#{Integer(id)}"
      end

      def remote_path(id, _setting)
        "documents/#{Integer(id)}"
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        raise Error, "Enable the Documents module on the destination project" unless project.module_enabled?(:documents)
        title = record.fetch("title")
        attributes = imported_attributes(record, mappings)
        mapping = store.find(key, record.fetch("id"))
        document = mapping && project.documents.find_by(id: mapping.fetch("destination_id"))
        if mapping && !document
          # Deleted locally: a conflict, or recreated when the source wins.
          Policy.local_change!("Local modification detected for document \"#{title}\": the document was deleted")
          TextFormat.note("recreated")
        elsif document && digest(local_state(document)) != mapping.fetch("destination_fingerprint")
          Policy.local_change!("Local modification detected for document \"#{title}\"")
          TextFormat.note("local_overwritten")
        end
        candidate = Document.new(project: project)
        candidate.assign_attributes(attributes.except("created_on"))
        raise Error, "Destination rejected document \"#{title}\": #{candidate.errors.full_messages.join(', ')}" unless candidate.valid?
        listed = record.fetch("attachments", [])
        new_attachments = listed.reject { |attachment| document && store.find(ATTACHMENTS, attachment.fetch("id")) }
        # Mirror mode: local files whose source file is gone.
        listed_ids = listed.map { |attachment| attachment.fetch("id") }
        removed = document && Policy.source_wins? && store.respond_to?(:mappings) ?
          store.mappings(ATTACHMENTS).select { |source_id, local_id| !listed_ids.include?(source_id) && document.attachments.exists?(id: local_id) } : []
        # Every file author is checked first, in the preview as well.
        attachment_attributes = new_attachments.to_h { |attachment| [attachment.fetch("id"), Attachments.new.imported_attributes(attachment, mappings)] }
        changed = document.nil? || local_state(document) != attributes || new_attachments.any? || removed.any?
        event = { module: key, source_id: record.fetch("id"), destination_id: document&.id, action: document ? (changed ? "update" : "unchanged") : "create" }
        return event unless apply && changed
        # Imported documents and files send no notification.
        Mailer.with_synched_deliveries do
          Mailer.with_deliveries(false) do
            MirrorMapping.transaction do
              removed.each do |source_id, local_id|
                document.attachments.find_by(id: local_id)&.destroy
                store.delete(ATTACHMENTS, source_id)
              end
              document ||= project.documents.new
              document.assign_attributes(attributes.except("created_on"))
              document.save!
              document.update_columns(created_on: Time.iso8601(attributes.fetch("created_on")))
              new_attachments.each do |attachment|
                file_attributes = attachment_attributes.fetch(attachment.fetch("id"))
                local = Attachments.new.import(attachment, file_attributes, document, source,
                  path: "mirror/source/attachments/#{Integer(attachment.fetch('id'))}/download")
                store.save(ATTACHMENTS, attachment.fetch("id"), "destination_id" => local.id,
                  "source_fingerprint" => digest(file_attributes), "destination_fingerprint" => digest(Attachments.new.local_attributes(local)))
              end
              document.reload
              store.save(key, record.fetch("id"), "destination_id" => document.id,
                "source_fingerprint" => digest(attributes.merge("attachments" => listed_ids)), "destination_fingerprint" => digest(local_state(document)))
            end
          end
        end
        event.merge(destination_id: document.id)
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "mirror/source/documents/#{Integer(source_id)}.json", source_project_id: source_project_id)
      end

      # The document's files go with it.
      def delete_local(destination_id, project_id)
        Document.where(project_id: project_id).find_by(id: destination_id)&.destroy
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      def imported_attributes(record, mappings)
        { "title" => record.fetch("title"), "description" => TextFormat.convert(record["description"].to_s),
          "category_id" => map(mappings, "document_category", record.fetch("category").fetch("id")),
          "created_on" => Time.iso8601(record.fetch("created_on")).utc.iso8601 }
      end

      def local_state(document)
        { "title" => document.title, "description" => document.description.to_s,
          "category_id" => document.category_id, "created_on" => document.created_on.utc.iso8601 }
      end
    end
  end
end
