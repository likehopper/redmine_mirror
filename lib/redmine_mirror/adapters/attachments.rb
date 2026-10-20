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
      def key; "issue_attachments"; end
      def association; "attachments"; end

      def imported_attributes(record, mappings)
        { "author_id" => author_id(record, mappings), "created_on" => Time.iso8601(record.fetch("created_on")).utc.iso8601,
          "filename" => record.fetch("filename"), "description" => record["description"].to_s,
          "content_type" => record.fetch("content_type"), "filesize" => Integer(record.fetch("filesize")) }
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
        attachment.destroy
        import(record, attributes, issue, source)
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "attachments/#{Integer(source_id)}.json")
      end

      def delete_local(destination_id, project_id)
        attachment = Attachment.find_by(id: destination_id)
        attachment.destroy if attachment && attachment.project&.id == project_id
      end

      # path: where a Mirror source serves the file, instead of the attachments API.
      def import(record, attributes, issue, source, path: nil)
        # The destination's own limit (Administration > Files) is the one that matters.
        limit = Setting.attachment_max_size.to_i * 1024
        if attributes.fetch("filesize") > limit
          raise Error, "Attachment #{attributes['filename']} (#{attributes.fetch('filesize') / 1024} KB) exceeds the destination's maximum attachment size (#{limit / 1024} KB)"
        end
        bytes = path ? source.download_attachment(record.fetch("id"), max_bytes: limit, path: path) : source.download_attachment(record.fetch("id"), max_bytes: limit)
        raise Error, "Attachment size mismatch" unless bytes.bytesize == attributes.fetch("filesize")
        Tempfile.create("mirror-attachment") do |file|
          file.binmode
          file.write(bytes)
          file.rewind
          attachment = issue.attachments.new(attributes.except("filesize"))
          attachment.file = file
          attachment.filename = attributes.fetch("filename")
          attachment.save!
          attachment
        end
      end
    end
  end
end
