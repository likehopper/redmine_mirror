# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/source_changes.rb
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
# Persist source changes for incremental runs. Destinations keep their own position and
# failures: the source stores nothing on their behalf.

require "active_support/concern"

module RedmineMirror
  module SourceChanges
    RETENTION = 180 * 24 * 60 * 60
    PAGE_SIZE = 1_000
    # Journal row marking a gap (suspension, journal error): every destination whose
    # position is before it makes a complete pass. Never sent to destinations.
    RESYNC_KEY = "resync"
    # Modules whose objects follow the visibility of their issue (parent_id, or source_id
    # for the issue itself).
    ISSUE_MODULES = %w[issue_tracking issue_hierarchy issue_journals issue_attachments issue_relations
      issue_watchers issue_custom_fields].freeze
    # Modules otherwise read in full whose journal entries let a destination read only
    # what changed. Older sources do not send the list: destinations then read everything.
    JOURNALED_MODULES = %w[wiki].freeze

    module_function

    # Only projects with Mirror source settings keep a journal. Keep it while sharing is
    # temporarily disabled: otherwise changes made during maintenance would disappear
    # from an already configured destination.
    def record(project_id, module_key, source_id, action: "upsert", parent_id: nil)
      return unless source_id && configured?(project_id)
      MirrorSourceChange.create!(project_id: project_id, module_key: module_key, source_id: source_id,
        action: action, parent_id: parent_id, created_at: Time.current)
    end

    # Within a request, Active Record's query cache answers the repeated lookups of one
    # save (an issue, its journal, custom values and watchers): unconfigured projects
    # cost one indexed read and no write.
    def configured?(project_id)
      project_id.present? && MirrorSourceSetting.where(project_id: project_id).exists?
    end

    # Run a model callback's journaling. While the administrator suspends the journal,
    # nothing is read or written. Callbacks run after the commit, or before a destroy:
    # a journal error must not fail or roll back the person's save. The destinations of
    # the projects concerned, or of every project when unknown, then resynchronize.
    def safely(*project_ids)
      return unless RedmineMirror::Source.changes_enabled?
      yield
    rescue StandardError => error
      Rails.logger.error("Mirror source could not record a change: #{error.class}: #{error.message}")
      ids = project_ids.compact.uniq
      ids.empty? ? require_full_resync : ids.each { |id| require_full_resync(id) }
    end

    # Ask destinations for a complete pass at their next run, after a gap in the
    # journal: those of one project, or of every Mirror source project. The marker row
    # is newer than any position a destination holds, so each one is behind it. When the
    # journal cannot even take the marker, the boundary goes one past its last entry:
    # destinations then make complete passes until the next entry is recorded.
    def require_full_resync(project_id = nil)
      project_ids = project_id ? [project_id] : MirrorSourceSetting.distinct.pluck(:project_id)
      project_ids.each do |id|
        boundary = begin
          MirrorSourceChange.create!(project_id: id, module_key: RESYNC_KEY, source_id: 1, action: "upsert",
            created_at: Time.current).id
        rescue ActiveRecord::ActiveRecordError
          MirrorSourceChange.where(project_id: id).maximum(:id).to_i + 1
        end
        state = MirrorSourceChangeState.find_or_create_by!(project_id: id)
        state.update!(discarded_before_id: [state.discarded_before_id.to_i, boundary].max)
      end
    rescue StandardError => error
      Rails.logger.error("Mirror source could not request a complete pass: #{error.class}: #{error.message}")
    end

    # Return the last event of each object after +after+. Intermediate states are
    # irrelevant: the destination needs the current object, or an explicit tombstone.
    # Without +after+ (a destination starting a complete pass), or with a position outside
    # the kept journal, the answer asks for a complete pass and gives the position to keep
    # once it is done. Reading writes nothing but the expiry of old entries.
    def page(project, after: nil, user: User.current, limit: PAGE_SIZE)
      prune(project)
      discarded_before = MirrorSourceChangeState.where(project_id: project.id).pluck(:discarded_before_id).first.to_i
      high_water = MirrorSourceChange.where(project_id: project.id).maximum(:id).to_i
      if after.nil? || after < discarded_before || after > high_water
        return { cursor: high_water, high_water: high_water, full_required: true, changes: [] }
      end

      rows = MirrorSourceChange.where(project_id: project.id)
        .where("mirror_source_changes.id > ? AND mirror_source_changes.id <= ?", after, high_water)
        .order("mirror_source_changes.id").limit(limit).to_a
      latest = rows.each_with_object({}) { |row, result| result[[row.module_key, row.source_id]] = row }
      cursor = rows.last&.id || high_water
      { cursor: cursor, high_water: high_water, full_required: false, journaled_modules: JOURNALED_MODULES,
        changes: visible(latest.values, user).map { |row| row.attributes.slice("id", "module_key", "source_id", "action", "parent_id").compact } }
    end

    # Objects the API account cannot see are left out: private issues, private notes,
    # time entries it may not view (Redmine shows time entries by project permission,
    # even on a private issue). A deletion names an object that no longer exists,
    # whose permissions cannot be checked anymore: it is kept.
    def visible(rows, user)
      rows = rows.reject { |row| row.module_key == RESYNC_KEY }
      upserts = rows.reject { |row| row.action == "delete" }
      issue_ids = upserts.select { |row| ISSUE_MODULES.include?(row.module_key) }.map { |row| row.parent_id || row.source_id }
      journal_ids = upserts.select { |row| row.module_key == "issue_journals" }.map(&:source_id)
      time_entry_ids = upserts.select { |row| row.module_key == "time_tracking" }.map(&:source_id)
      issues = issue_ids.empty? ? [] : Issue.visible(user).where(id: issue_ids).pluck(:id)
      journals = journal_ids.empty? ? [] : Journal.visible(user).where(id: journal_ids).pluck(:id)
      time_entries = time_entry_ids.empty? ? [] : TimeEntry.visible(user).where(id: time_entry_ids).pluck(:id)
      rows.select do |row|
        if row.action == "delete" then true
        elsif row.module_key == "issue_journals" then journals.include?(row.source_id)
        elsif ISSUE_MODULES.include?(row.module_key) then issues.include?(row.parent_id || row.source_id)
        elsif row.module_key == "time_tracking" then time_entries.include?(row.source_id)
        else true
        end
      end
    end

    def prune(project)
      expired = MirrorSourceChange.where(project_id: project.id).where("created_at < ?", Time.current - RETENTION)
      boundary = expired.maximum(:id)
      return unless boundary
      MirrorSourceChangeState.transaction do
        state = MirrorSourceChangeState.lock.find_or_create_by!(project_id: project.id)
        state.update!(discarded_before_id: [state.discarded_before_id.to_i, boundary].max)
        expired.delete_all
      end
    end

    module IssuePatch
      extend ActiveSupport::Concern
      included do
        before_destroy :mirror_record_dependent_deletions
        after_commit :mirror_record_issue_changes, on: %i[create update]
        after_commit :mirror_record_issue_deletion, on: :destroy
      end

      def mirror_record_issue_changes
        previous_project_id = previous_changes.fetch("project_id", []).first
        moved = previous_project_id && previous_project_id != project_id
        RedmineMirror::SourceChanges.safely(moved ? previous_project_id : nil, project_id) do
          # Reading the moved issue's children costs queries: only for a journaled project.
          if moved && (RedmineMirror::SourceChanges.configured?(previous_project_id) || RedmineMirror::SourceChanges.configured?(project_id))
            RedmineMirror::SourceChanges.record(previous_project_id, "issue_tracking", id, action: "delete")
            RedmineMirror::SourceChanges.record(previous_project_id, "issue_hierarchy", id, action: "delete", parent_id: id)
            journals.pluck(:id).each do |child_id|
              RedmineMirror::SourceChanges.record(previous_project_id, "issue_journals", child_id, action: "delete", parent_id: id)
              RedmineMirror::SourceChanges.record(project_id, "issue_journals", child_id, parent_id: id)
            end
            attachments.pluck(:id).each do |child_id|
              RedmineMirror::SourceChanges.record(previous_project_id, "issue_attachments", child_id, action: "delete", parent_id: id)
              RedmineMirror::SourceChanges.record(project_id, "issue_attachments", child_id, parent_id: id)
            end
            relations.each do |relation|
              RedmineMirror::SourceChanges.record(previous_project_id, "issue_relations", relation.id, action: "delete", parent_id: id)
              RedmineMirror::SourceChanges.record(project_id, "issue_relations", relation.id, parent_id: id)
            end
            RedmineMirror::SourceChanges.record(project_id, "issue_watchers", id, parent_id: id)
            RedmineMirror::SourceChanges.record(project_id, "issue_custom_fields", id, parent_id: id)
          end
          RedmineMirror::SourceChanges.record(project_id, "issue_tracking", id)
          RedmineMirror::SourceChanges.record(project_id, "issue_hierarchy", id, parent_id: id)
        end
      end

      def mirror_record_issue_deletion
        RedmineMirror::SourceChanges.safely(project_id) do
          RedmineMirror::SourceChanges.record(project_id, "issue_tracking", id, action: "delete")
        end
      end

      def mirror_record_dependent_deletions
        RedmineMirror::SourceChanges.safely(project_id) do
          next unless RedmineMirror::SourceChanges.configured?(project_id)
          # Inside the destroy's transaction: a savepoint keeps a journal error from
          # aborting it (PostgreSQL refuses any statement after a failed one).
          MirrorSourceChange.transaction(requires_new: true) do
            journals.pluck(:id).each do |child_id|
              RedmineMirror::SourceChanges.record(project_id, "issue_journals", child_id, action: "delete", parent_id: id)
            end
            attachments.pluck(:id).each do |child_id|
              RedmineMirror::SourceChanges.record(project_id, "issue_attachments", child_id, action: "delete", parent_id: id)
            end
            relations.each do |relation|
              RedmineMirror::SourceChanges.record(project_id, "issue_relations", relation.id, action: "delete", parent_id: id)
            end
          end
        end
      end
    end

    module TimeEntryPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_time_entry_change, on: %i[create update]
        after_commit :mirror_record_time_entry_deletion, on: :destroy
      end

      def mirror_record_time_entry_change
        previous_project_id = previous_changes.fetch("project_id", []).first
        moved = previous_project_id && previous_project_id != project_id
        RedmineMirror::SourceChanges.safely(moved ? previous_project_id : nil, project_id) do
          RedmineMirror::SourceChanges.record(previous_project_id, "time_tracking", id, action: "delete") if moved
          RedmineMirror::SourceChanges.record(project_id, "time_tracking", id)
        end
      end

      def mirror_record_time_entry_deletion
        RedmineMirror::SourceChanges.safely(project_id) do
          RedmineMirror::SourceChanges.record(project_id, "time_tracking", id, action: "delete")
        end
      end
    end

    module MemberPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_member_change, on: %i[create update]
        after_commit :mirror_record_member_deletion, on: :destroy
      end

      def mirror_record_member_change
        previous_project_id = previous_changes.fetch("project_id", []).first
        moved = previous_project_id && previous_project_id != project_id
        RedmineMirror::SourceChanges.safely(moved ? previous_project_id : nil, project_id) do
          RedmineMirror::SourceChanges.record(previous_project_id, "project_members", id, action: "delete") if moved
          RedmineMirror::SourceChanges.record(project_id, "project_members", id)
        end
      end

      def mirror_record_member_deletion
        RedmineMirror::SourceChanges.safely(project_id) do
          RedmineMirror::SourceChanges.record(project_id, "project_members", id, action: "delete")
        end
      end
    end

    module MemberRolePatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_member_change
      end

      def mirror_record_member_change
        RedmineMirror::SourceChanges.safely do
          member = Member.find_by(id: member_id)
          RedmineMirror::SourceChanges.record(member.project_id, "project_members", member.id) if member
        end
      end
    end

    module JournalPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_journal_change
      end

      def mirror_record_journal_change
        return unless journalized_type == "Issue"
        RedmineMirror::SourceChanges.safely do
          project_id = Issue.where(id: journalized_id).limit(1).pluck(:project_id).first
          action = destroyed? ? "delete" : "upsert"
          RedmineMirror::SourceChanges.record(project_id, "issue_journals", id, action: action, parent_id: journalized_id)
        end
      end
    end

    module AttachmentPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_issue_attachment_change
      end

      def mirror_record_issue_attachment_change
        return mirror_record_wiki_attachment_change if container_type == "WikiPage"
        return unless container_type == "Issue"
        RedmineMirror::SourceChanges.safely do
          project_id = Issue.where(id: container_id).limit(1).pluck(:project_id).first
          action = destroyed? ? "delete" : "upsert"
          RedmineMirror::SourceChanges.record(project_id, "issue_attachments", id, action: action, parent_id: container_id)
        end
      end

      # Attaching or removing a file keeps the page version: destinations read the index
      # for text edits, and the journal for files. The page is named by its title key.
      # A deleted page takes its files with it; the index reports the page itself.
      def mirror_record_wiki_attachment_change
        RedmineMirror::SourceChanges.safely do
          project_id, title = WikiPage.joins(:wiki).where(id: container_id).limit(1).pluck("wikis.project_id", :title).first
          RedmineMirror::SourceChanges.record(project_id, "wiki", RedmineMirror::Adapters::Wiki.source_id(title)) if title
        end
      end
    end

    module IssueRelationPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_relation_change
      end

      def mirror_record_relation_change
        RedmineMirror::SourceChanges.safely do
          owner_id = issue_from_id
          project_id = Issue.where(id: owner_id).limit(1).pluck(:project_id).first ||
            Issue.where(id: issue_to_id).limit(1).pluck(:project_id).first
          action = destroyed? ? "delete" : "upsert"
          RedmineMirror::SourceChanges.record(project_id, "issue_relations", id, action: action, parent_id: owner_id)
        end
      end
    end

    module IssueAssociationPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_issue_association_change
      end

      def mirror_record_issue_association_change
        issue_id = if respond_to?(:watchable_type) && watchable_type == "Issue"
                     watchable_id
                   elsif respond_to?(:customized_type) && customized_type == "Issue"
                     customized_id
                   end
        return unless issue_id
        RedmineMirror::SourceChanges.safely do
          project_id = Issue.where(id: issue_id).limit(1).pluck(:project_id).first
          module_key = respond_to?(:watchable_type) ? "issue_watchers" : "issue_custom_fields"
          RedmineMirror::SourceChanges.record(project_id, module_key, issue_id)
        end
      end
    end
  end
end
