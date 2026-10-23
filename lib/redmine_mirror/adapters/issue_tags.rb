# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/issue_tags.rb
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
# Copy the current tags of imported issues (Redmine Tags plugin by RedmineUP).

module RedmineMirror
  module Adapters
    # Tags have no REST API: the source must run Mirror and share them (Mirror source).
    # Their history needs nothing more: tag changes are journal details, imported with
    # the other history. Only the tags Mirror adds are its own, as for watchers.
    class IssueTags < Base
      SOURCE_VERSION = "1.0.0-beta.28"

      def key; "issue_tags"; end
      def project_module; :issue_tracking; end
      def phase; :history; end
      def dependencies; ["issue_tracking"]; end
      def record_label; :label_mirror_statistic_issues; end
      def catalog_statistics(record); { "tags" => record.fetch("tags").size }; end

      # The destination needs the Redmine Tags plugin too.
      def available?
        Issue.method_defined?(:tag_list)
      end

      REFUSALS = {
        "disabled" => "Mirror source is disabled on the source Redmine: its administrator must allow it (Administration → Plugins → Redmine Mirror)",
        "module" => "Enable the Mirror source module on the source project",
        "not_shared" => "Share Tags in the source project's Settings → Mirror source",
        "permission" => "The source API key needs View issues in the source project",
        "unavailable" => "The source Redmine has no Redmine Tags plugin"
      }.freeze

      def selection_hint; :text_mirror_issue_tags_source_hint; end

      def records(client, project_id)
        client.get("projects/#{Integer(project_id)}/mirror/source/issue_tags.json").fetch("issue_tags").map do |row|
          { "id" => row.fetch("id"), "project" => { "id" => Integer(project_id) }, "tags" => row.fetch("tags").map(&:to_s) }
        end
      rescue Error => error
        reason = error.message[/\(Mirror source: ([a-z_]+)\)/, 1]
        raise Error, REFUSALS.fetch(reason) if REFUSALS.key?(reason)
        raise Error, "The source Redmine does not list tags: install Redmine Mirror #{SOURCE_VERSION} or later on it" if error.message.include?("HTTP 404")
        raise Error, REFUSALS.fetch("permission") if error.message.include?("HTTP 403") || error.message.include?("HTTP 401")
        raise
      end

      def local_path(id, _project)
        "/issues/#{Integer(id)}"
      end

      def remote_path(id, _setting)
        "issues/#{Integer(id)}"
      end

      # Additive outside mirror mode: local tags are kept, and a tag added from the
      # source then removed locally while the source still has it is a conflict. Mirror
      # mode sets exactly the source tags.
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        raise Error, "Install the Redmine Tags plugin on this Redmine" unless available?
        source_tags = normalize(record.fetch("tags"))
        local_id = lookup.call("issue_tracking", record.fetch("id"))
        event = { module: key, source_id: record.fetch("id"), destination_id: local_id, action: "unchanged" }
        issue = Issue.find_by(id: local_id, project_id: project_id) unless local_id.nil? || local_id.to_s.start_with?("planned:")
        unless issue
          # An issue without tags needs nothing; one with tags waits for its issue.
          raise Error, "Missing destination issue correspondence" if apply && source_tags.any? && !local_id.to_s.start_with?("planned:")
          event[:action] = "update" if source_tags.any?
          return event
        end
        current = normalize(read_tags(issue))
        desired = if Policy.source_wins?
          source_tags
        else
          previous = store.find(key, record.fetch("id"))
          if previous && previous.fetch("source_fingerprint") == digest(source_tags) &&
             digest(common(source_tags, current)) != previous.fetch("destination_fingerprint")
            raise Error, "Local modification detected for #{key}: a tag added from the source was removed locally"
          end
          normalize(current + source_tags)
        end
        changed = !same?(desired, current)
        return event if !changed && store.find(key, record.fetch("id")).nil? && source_tags.empty?
        event[:action] = changed ? "update" : "unchanged"
        return event unless apply
        MirrorMapping.transaction do
          write_tags(issue, desired) if changed
          store.save(key, record.fetch("id"), "destination_id" => issue.id, "source_fingerprint" => digest(source_tags),
            "destination_fingerprint" => digest(common(source_tags, normalize(read_tags(issue.reload)))))
        end
        event
      end

      def read_tags(issue)
        issue.tag_list.to_a
      end

      # Tags only: the issue is not saved, so no journal nor notification.
      def write_tags(issue, names)
        issue.tag_list = names
        issue.save_tags
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      # Tag names compare without case, as Redmine Tags finds them.
      def normalize(tags)
        tags.to_a.map { |name| name.to_s.strip }.reject(&:empty?).uniq { |name| name.downcase }.sort_by(&:downcase)
      end

      def same?(left, right)
        left.map(&:downcase) == right.map(&:downcase)
      end

      def common(source_tags, local_tags)
        names = local_tags.map(&:downcase)
        source_tags.select { |name| names.include?(name.downcase) }
      end
    end
  end
end
