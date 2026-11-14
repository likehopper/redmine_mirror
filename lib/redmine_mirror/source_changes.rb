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
# Persist source changes and per-destination acknowledgements for incremental runs.

require "active_support/concern"

module RedmineMirror
  module SourceChanges
    RETENTION = 180 * 24 * 60 * 60
    PAGE_SIZE = 1_000

    module_function

    def record(project_id, module_key, source_id, action: "upsert", parent_id: nil)
      return unless project_id && source_id
      project = Project.find_by(id: project_id)
      # Keep the journal while sharing is temporarily disabled. Otherwise changes made
      # during maintenance would disappear from an already configured destination.
      return unless project&.mirror_source_setting
      MirrorSourceChange.create!(project_id: project.id, module_key: module_key, source_id: source_id,
        action: action, parent_id: parent_id, created_at: Time.current)
    end

    # Return the last event for each object. Intermediate states are irrelevant: the
    # destination needs the current object, or an explicit tombstone.
    def page(project, consumer_key:, after: 0, limit: PAGE_SIZE)
      prune(project)
      state = MirrorSourceChangeState.find_or_create_by!(project_id: project.id)
      consumer = MirrorSourceConsumer.find_or_create_by!(project_id: project.id, consumer_key: consumer_key)
      high_water = MirrorSourceChange.where(project_id: project.id).maximum(:id).to_i
      return { cursor: high_water, high_water: high_water, full_required: true, changes: [] } if consumer.baseline_change_id.to_i < state.discarded_before_id.to_i

      acknowledgements = MirrorSourceAcknowledgement.where(project_id: project.id, consumer_key: consumer_key)
        .select(:module_key, :source_id, :change_id)
      rows = MirrorSourceChange.where(project_id: project.id).where("mirror_source_changes.id > ? AND mirror_source_changes.id <= ?", [after.to_i, consumer.baseline_change_id.to_i].max, high_water)
        .joins("LEFT OUTER JOIN (#{acknowledgements.to_sql}) mirror_source_acks ON mirror_source_acks.module_key = mirror_source_changes.module_key " \
          "AND mirror_source_acks.source_id = mirror_source_changes.source_id")
        .where("mirror_source_acks.change_id IS NULL OR mirror_source_changes.id > mirror_source_acks.change_id")
        .order("mirror_source_changes.id").limit(limit).to_a
      latest = rows.each_with_object({}) { |row, result| result[[row.module_key, row.source_id]] = row }
      cursor = rows.last&.id || high_water
      { cursor: cursor, high_water: high_water, full_required: false,
        changes: latest.values.map { |row| row.attributes.slice("id", "module_key", "source_id", "action", "parent_id").compact } }
    end

    def acknowledge(project, consumer_key:, changes: [], baseline: nil, pending: [])
      MirrorSourceConsumer.transaction do
        consumer = MirrorSourceConsumer.lock.find_or_create_by!(project_id: project.id, consumer_key: consumer_key)
        if baseline
          value = Integer(baseline)
          maximum = MirrorSourceChange.where(project_id: project.id).maximum(:id).to_i
          raise ArgumentError if value.negative? || value > maximum
          consumer.update!(baseline_change_id: [consumer.baseline_change_id.to_i, value].max)
        end
        changes.each do |change|
          event = MirrorSourceChange.find_by(id: Integer(change.fetch("id")), project_id: project.id,
            module_key: change.fetch("module_key"), source_id: Integer(change.fetch("source_id")))
          raise ArgumentError unless event
          row = MirrorSourceAcknowledgement.find_or_initialize_by(project_id: project.id, consumer_key: consumer_key,
            module_key: change.fetch("module_key"), source_id: Integer(change.fetch("source_id")))
          change_id = event.id
          next if row.persisted? && row.change_id >= change_id
          row.update!(change_id: change_id)
        end
        pending.each do |change|
          record(project.id, change.fetch("module_key"), Integer(change.fetch("source_id")),
            parent_id: change["parent_id"] && Integer(change["parent_id"]))
        end
        consumer.touch
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
        after_commit -> { RedmineMirror::SourceChanges.record(project_id, "issue_tracking", id, action: "delete") }, on: :destroy
      end


      def mirror_record_issue_changes
        previous_project_id = previous_changes.fetch("project_id", []).first
        if previous_project_id && previous_project_id != project_id
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

      def mirror_record_dependent_deletions
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

    module TimeEntryPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_time_entry_change, on: %i[create update]
        after_commit -> { RedmineMirror::SourceChanges.record(project_id, "time_tracking", id, action: "delete") }, on: :destroy
      end


      def mirror_record_time_entry_change
        previous_project_id = previous_changes.fetch("project_id", []).first
        RedmineMirror::SourceChanges.record(previous_project_id, "time_tracking", id, action: "delete") if previous_project_id && previous_project_id != project_id
        RedmineMirror::SourceChanges.record(project_id, "time_tracking", id)
      end
    end

    module MemberPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_member_change, on: %i[create update]
        after_commit -> { RedmineMirror::SourceChanges.record(project_id, "project_members", id, action: "delete") }, on: :destroy
    end

      def mirror_record_member_change
        previous_project_id = previous_changes.fetch("project_id", []).first
        RedmineMirror::SourceChanges.record(previous_project_id, "project_members", id, action: "delete") if previous_project_id && previous_project_id != project_id
        RedmineMirror::SourceChanges.record(project_id, "project_members", id)
      end
    end

    module MemberRolePatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_member_change
      end

      def mirror_record_member_change
        member = Member.find_by(id: member_id)
        RedmineMirror::SourceChanges.record(member.project_id, "project_members", member.id) if member
      end
    end

    module JournalPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_journal_change
      end

      def mirror_record_journal_change
        return unless journalized_type == "Issue"
        project_id = Issue.where(id: journalized_id).limit(1).pluck(:project_id).first
        action = destroyed? ? "delete" : "upsert"
        RedmineMirror::SourceChanges.record(project_id, "issue_journals", id, action: action, parent_id: journalized_id)
      end
    end

    module AttachmentPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_issue_attachment_change
      end

      def mirror_record_issue_attachment_change
        return unless container_type == "Issue"
        project_id = Issue.where(id: container_id).limit(1).pluck(:project_id).first
        action = destroyed? ? "delete" : "upsert"
        RedmineMirror::SourceChanges.record(project_id, "issue_attachments", id, action: action, parent_id: container_id)
      end
    end

    module IssueRelationPatch
      extend ActiveSupport::Concern
      included do
        after_commit :mirror_record_relation_change
      end

      def mirror_record_relation_change
        owner_id = issue_from_id
        project_id = Issue.where(id: owner_id).limit(1).pluck(:project_id).first ||
          Issue.where(id: issue_to_id).limit(1).pluck(:project_id).first
        action = destroyed? ? "delete" : "upsert"
        RedmineMirror::SourceChanges.record(project_id, "issue_relations", id, action: action, parent_id: owner_id)
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
        project_id = Issue.where(id: issue_id).limit(1).pluck(:project_id).first
        module_key = respond_to?(:watchable_type) ? "issue_watchers" : "issue_custom_fields"
        RedmineMirror::SourceChanges.record(project_id, module_key, issue_id)
      end
    end
  end
end
