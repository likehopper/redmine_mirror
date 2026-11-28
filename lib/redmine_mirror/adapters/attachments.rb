# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/attachments.rb
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
# Copy bounded source files and preserve their metadata in native attachment storage.

require "tempfile"
require "time"
module RedmineMirror
  module Adapters
    class Attachments < IssueChildren
      # What to do when the source no longer has an issue attachment's file (HTTP 404):
      # retry at every run (default), stop synchronizing it, or write a placeholder file
      # under the same name so that the issue keeps the entry.
      MISSING_FILE = %w[retry skip placeholder].freeze
      # A provisional mapping must never match the real source fingerprint.
      MISSING_FINGERPRINT = ("0" * 64).freeze
      PLACEHOLDER_ASSETS = { ".pdf" => ["application/pdf", "pdf"], ".png" => ["image/png", "png"],
        ".jpg" => ["image/jpeg", "jpg"], ".jpeg" => ["image/jpeg", "jpg"],
        ".gif" => ["image/gif", "gif"], ".webp" => ["image/webp", "webp"] }.freeze

      # The source has no file for this attachment and the project chose to stop asking.
      class MissingSourceFile < Error; end

      def key; "issue_attachments"; end
      def association; "attachments"; end
      def catalog_statistics(record); { "bytes" => record["filesize"].to_i }.merge(file_size_statistics([record])); end
      def overview_checks(_project, _setting, statistics); oversized_checks(statistics); end

      def imported_attributes(record, mappings)
        { "author_id" => author_id(record, mappings), "created_on" => Time.iso8601(record.fetch("created_on")).utc.iso8601,
          "filename" => record.fetch("filename"), "description" => record["description"].to_s,
          "content_type" => record.fetch("content_type"), "filesize" => Integer(record.fetch("filesize")) }
      end

      def configuration_options(input, _project)
        raise Error, "Unsupported attachment options" unless (input.keys - ["missing_file"]).empty?
        { "missing_file" => input["missing_file"].presence_in(MISSING_FILE) || "retry" }
      end

      # Ignored instead of failing: the object is not retried and its issue is not blocked.
      def synchronize(record, recover_missing_files: false, **options)
        @recover_missing_files = recover_missing_files
        @retrying_placeholder = options.fetch(:store).find(key, record.fetch("id"))&.fetch("source_fingerprint") == MISSING_FINGERPRINT
        super(record, **options)
      rescue MissingSourceFile => error
        { module: key, source_id: record.fetch("id"), action: "ignored", reason: error.message }
      end

      def find_target(id, issue)
        raise Error, "Missing destination issue" unless issue
        issue.attachments.find(id)
      end

      def local_attributes(attachment)
        raise Error, "Missing destination attachment file" unless File.file?(attachment.diskfile)
        attachment.attributes.slice("author_id", "filename", "description", "content_type", "filesize").merge(
          "created_on" => attachment.created_on.utc.iso8601, "sha256" => Digest::SHA256.file(attachment.diskfile).hexdigest)
      end

      # A file cannot be edited in place: the local one is replaced.
      def overwrite(attachment, record, attributes, issue, source)
        replacement = import(record, attributes, issue, source, existing: (@retrying_placeholder ? attachment : nil))
        attachment.destroy unless replacement.id == attachment.id
        replacement
      end

      def imported_source_fingerprint(fingerprint)
        @last_import_placeholder ? MISSING_FINGERPRINT : fingerprint
      end

      def retain_placeholder?(mapping)
        mapping["source_fingerprint"] == MISSING_FINGERPRINT && !@recover_missing_files
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "attachments/#{Integer(source_id)}.json")
      end

      def delete_local(destination_id, project_id)
        attachment = Attachment.find_by(id: destination_id)
        attachment.destroy if attachment && attachment.project&.id == project_id
      end

      # path: where a Mirror source serves the file, instead of the attachments API.
      def import(record, attributes, issue, source, path: nil, existing: nil)
        @last_import_placeholder = false
        raise Error, "Missing destination attachment container" unless issue&.persisted?
        raise Error, "Missing destination attachment author" unless User.exists?(id: attributes.fetch("author_id"))
        # The destination's own limit (Administration > Files) is the one that matters.
        limit = Setting.attachment_max_size.to_i * 1024
        if attributes.fetch("filesize") > limit
          raise Error, "Attachment #{attributes['filename']} (#{attributes.fetch('filesize') / 1024} KB) exceeds the destination's maximum attachment size (#{limit / 1024} KB)"
        end
        placeholder = false
        bytes = begin
          path ? source.download_attachment(record.fetch("id"), max_bytes: limit, path: path) : source.download_attachment(record.fetch("id"), max_bytes: limit)
        rescue Error => error
          raise unless path.nil? && (issue.is_a?(Issue) || issue.is_a?(WikiPage)) && error.message.match?(/HTTP 404 for GET \S*attachments\/download/)
          case missing_file_choice(issue)
          when "skip" then raise MissingSourceFile, "Source file missing: not synchronized, as chosen in the module options"
          when "placeholder" then placeholder = true
          else raise
          end
          @last_import_placeholder = true
          return existing if existing && existing.persisted?
          placeholder_content(attributes)
        end
        content_type, bytes = bytes if placeholder
        raise Error, "Attachment size mismatch" unless placeholder || bytes.bytesize == attributes.fetch("filesize")
        Tempfile.create("mirror-attachment") do |file|
          file.binmode
          file.write(bytes)
          file.rewind
          attachment = issue.attachments.new(attributes.except("filesize"))
          if placeholder
            attachment.content_type = content_type
            attachment.description = [::I18n.t(:text_mirror_missing_file_description, locale: Setting.default_language, default: "File not available on the source"),
              attributes["description"].presence].compact.join(" — ")
          end
          attachment.file = file
          attachment.filename = attributes.fetch("filename")
          attachment.save!
          TextFormat.note("missing_file_placeholder") if placeholder
          attachment
        end
      end

      private

      def missing_file_choice(issue)
        project = issue.is_a?(WikiPage) ? issue.wiki.project : issue.project
        module_key = issue.is_a?(WikiPage) ? "wiki" : key
        project.mirror_project_setting&.module_options.to_h.fetch(module_key, {})["missing_file"].presence_in(MISSING_FILE) || "retry"
      end

      def placeholder_content(attributes)
        extension = File.extname(attributes.fetch("filename")).downcase
        format = PLACEHOLDER_ASSETS[extension]
        format ||= ["image/png", "png"] if attributes.fetch("content_type").start_with?("image/")
        return ["text/plain", placeholder_text(attributes)] unless format
        [format.first, File.binread(File.expand_path("../../../assets/missing-attachment.#{format.last}", __dir__))]
      end

      # Same name, so that links and inline references in the issue still find it.
      def placeholder_text(attributes)
        ::I18n.t(:text_mirror_missing_file_content, locale: Setting.default_language, filename: attributes.fetch("filename"),
          size: attributes.fetch("filesize"), default: "This file was not available on the source Redmine when it was imported: %{filename} (%{size} bytes).") + "\n"
      end
    end
  end
end
