# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/news.rb
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
# Import news with their author, date, comments and files through local models.

require "time"

module RedmineMirror
  module Adapters
    # News have a REST API, but not their comments nor their files: the source must
    # run Mirror and share its news (Mirror source, MirrorSourceApiController).
    class News < Base
      SOURCE_VERSION = "1.0.0-beta.26"
      # Comments and files have their own correspondences, inside the News module.
      COMMENTS = "news_comments"
      ATTACHMENTS = "news_attachments"

      def key; "news"; end
      def project_module; :news; end
      def phase; :history; end
      def dependencies; ["users"]; end

      def text_samples(record)
        [record["description"]] + record.fetch("comments", []).map { |comment| comment["content"] }
      end

      def referenced_users(record)
        ([record["author"]] + record.fetch("comments", []).map { |comment| comment["author"] } +
          record.fetch("attachments", []).map { |attachment| attachment["author"] }).compact
      end

      def catalog_statistics(record); file_size_statistics(record.fetch("attachments", [])); end
      def overview_checks(_project, _setting, statistics); oversized_checks(statistics); end

      # What the source must change, for each lock it names (Source.refusal).
      REFUSALS = {
        "disabled" => "Mirror source is disabled on the source Redmine: its administrator must allow it, and this data (Administration → Plugins → Redmine Mirror)",
        "module" => "Enable the Mirror source module on the source project",
        "not_shared" => "Share News in the source project's Settings → Mirror source",
        "permission" => "The source API key needs View news in the source project"
      }.freeze

      # Shown next to the module in the connection form.
      def selection_hint; :text_mirror_news_source_hint; end

      def records(client, project_id)
        client.get("projects/#{Integer(project_id)}/mirror/source/news.json").fetch("news")
      rescue Error => error
        raise Error, "The source Redmine does not list news: install Redmine Mirror #{SOURCE_VERSION} or later on it" if error.message.include?("HTTP 404")
        reason = error.message[/\(Mirror source: ([a-z_]+)\)/, 1]
        raise Error, REFUSALS.fetch(reason, REFUSALS.fetch("permission")) if error.message.include?("HTTP 403") || error.message.include?("HTTP 401")
        raise
      end

      def local_path(id, _project)
        "/news/#{Integer(id)}"
      end

      def remote_path(id, _setting)
        "news/#{Integer(id)}"
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        raise Error, "Enable the News module on the destination project" unless project.module_enabled?(:news)
        title = record.fetch("title")
        attributes = imported_attributes(record, mappings)
        mapping = store.find(key, record.fetch("id"))
        news = mapping && project.news.find_by(id: mapping.fetch("destination_id"))
        if mapping && !news
          # Deleted locally: a conflict, or recreated when the source wins.
          Policy.local_change!("Local modification detected for news \"#{title}\": the news was deleted")
          TextFormat.note("recreated")
        elsif news && digest(local_state(news)) != mapping.fetch("destination_fingerprint")
          Policy.local_change!("Local modification detected for news \"#{title}\"")
          TextFormat.note("local_overwritten")
        end
        candidate = ::News.new(project: project)
        candidate.assign_attributes(attributes.except("created_on"))
        raise Error, "Destination rejected news \"#{title}\": #{candidate.errors.full_messages.join(', ')}" unless candidate.valid?
        # Every comment and file author is checked first, in the preview as well.
        comments = record.fetch("comments", []).to_h { |comment| [comment.fetch("id"), comment_attributes(comment, mappings)] }
        new_comments = comments.reject { |id, _| news && store.find(COMMENTS, id) }
        changed_comments = news ? comments.select { |id, values| (row = store.find(COMMENTS, id)) && row.fetch("source_fingerprint") != digest(values) } : {}
        listed = record.fetch("attachments", [])
        new_attachments = listed.reject { |attachment| news && store.find(ATTACHMENTS, attachment.fetch("id")) }
        attachment_attributes = new_attachments.to_h { |attachment| [attachment.fetch("id"), Attachments.new.imported_attributes(attachment, mappings)] }
        # Mirror mode: local comments and files whose source one is gone.
        removed_comments = gone(news, store, COMMENTS, comments.keys) { |local_id| news.comments.exists?(id: local_id) }
        removed_files = gone(news, store, ATTACHMENTS, listed.map { |attachment| attachment.fetch("id") }) { |local_id| news.attachments.exists?(id: local_id) }
        changed = news.nil? || local_state(news) != attributes || [new_comments, changed_comments, new_attachments, removed_comments, removed_files].any?(&:any?)
        event = { module: key, source_id: record.fetch("id"), destination_id: news&.id, action: news ? (changed ? "update" : "unchanged") : "create" }
        return event unless apply && changed
        # Imported news, comments and files send no notification.
        Mailer.with_synched_deliveries do
          Mailer.with_deliveries(false) do
            MirrorMapping.transaction do
              removed_comments.each do |source_id, local_id|
                news.comments.find_by(id: local_id)&.destroy
                store.delete(COMMENTS, source_id)
              end
              removed_files.each do |source_id, local_id|
                news.attachments.find_by(id: local_id)&.destroy
                store.delete(ATTACHMENTS, source_id)
              end
              news ||= project.news.new
              news.assign_attributes(attributes.except("created_on"))
              news.save!
              news.update_columns(created_on: Time.iso8601(attributes.fetch("created_on")))
              new_comments.merge(changed_comments).each do |source_id, values|
                comment = (row = store.find(COMMENTS, source_id)) && news.comments.find_by(id: row.fetch("destination_id"))
                comment ||= news.comments.new
                comment.assign_attributes(author_id: values.fetch("author_id"), comments: values.fetch("content"))
                comment.save!
                comment.update_columns(created_on: Time.iso8601(values.fetch("created_on")), updated_on: Time.iso8601(values.fetch("updated_on")))
                store.save(COMMENTS, source_id, "destination_id" => comment.id, "source_fingerprint" => digest(values),
                  "destination_fingerprint" => digest(comment.reload.attributes.slice("author_id", "comments")))
              end
              new_attachments.each do |attachment|
                file_attributes = attachment_attributes.fetch(attachment.fetch("id"))
                local = Attachments.new.import(attachment, file_attributes, news, source,
                  path: "mirror/source/attachments/#{Integer(attachment.fetch('id'))}/download")
                store.save(ATTACHMENTS, attachment.fetch("id"), "destination_id" => local.id,
                  "source_fingerprint" => digest(file_attributes), "destination_fingerprint" => digest(Attachments.new.local_attributes(local)))
              end
              news.reload
              store.save(key, record.fetch("id"), "destination_id" => news.id,
                "source_fingerprint" => digest(attributes.merge("comments" => comments.keys, "attachments" => listed.map { |attachment| attachment.fetch("id") })),
                "destination_fingerprint" => digest(local_state(news)))
            end
          end
        end
        event.merge(destination_id: news.id)
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "mirror/source/news/#{Integer(source_id)}.json", source_project_id: source_project_id)
      end

      # The news' comments and files go with it.
      def delete_local(destination_id, project_id)
        ::News.where(project_id: project_id).find_by(id: destination_id)&.destroy
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      # A missing or anonymized author is Redmine's anonymous user, as in the wiki.
      def author_id(reference, mappings)
        (reference && Users.new.resolve(mappings, reference.fetch("id"))) || User.anonymous.id
      end

      def imported_attributes(record, mappings)
        { "title" => record.fetch("title"), "summary" => record["summary"].to_s,
          "description" => TextFormat.convert(record["description"].to_s), "author_id" => author_id(record["author"], mappings),
          "created_on" => Time.iso8601(record.fetch("created_on")).utc.iso8601 }
      end

      def comment_attributes(comment, mappings)
        { "author_id" => author_id(comment["author"], mappings), "content" => TextFormat.convert(comment["content"].to_s),
          "created_on" => Time.iso8601(comment.fetch("created_on")).utc.iso8601,
          "updated_on" => Time.iso8601(comment["updated_on"] || comment.fetch("created_on")).utc.iso8601 }
      end

      def local_state(news)
        { "title" => news.title, "summary" => news.summary.to_s, "description" => news.description.to_s,
          "author_id" => news.author_id, "created_on" => news.created_on.utc.iso8601 }
      end

      # Mirror mode only: [source ID, local ID] of the correspondences whose source object
      # is no longer listed and whose local object still exists.
      def gone(news, store, kind, listed_ids)
        return [] unless news && Policy.source_wins? && store.respond_to?(:mappings)
        store.mappings(kind).select { |source_id, local_id| !listed_ids.include?(source_id) && yield(local_id) }
      end
    end
  end
end
