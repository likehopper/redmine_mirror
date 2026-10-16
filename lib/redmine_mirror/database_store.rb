# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/database_store.rb
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
# Persist scoped object identities, fingerprints, conflicts and deferred cross-project links.

module RedmineMirror
  class DatabaseStore
    def initialize(connection_key, project_id: nil)
      @connection_key = connection_key
      @project_id = project_id
    end

    def find(module_key, source_id)
      row = scope(module_key, source_id).first
      row && row.attributes.slice("destination_id", "source_fingerprint", "destination_fingerprint")
    end

    def save(module_key, source_id, attributes)
      row = scope(module_key, source_id).first_or_initialize
      row.project_id = @project_id if @project_id
      row.assign_attributes(attributes)
      row.save!
    end

    def excluded?(module_key, source_id)
      return false unless @project_id
      MirrorConflict.exists?(project_id: @project_id, connection_key: @connection_key, module_key: module_key, source_id: source_id, status: "ignored")
    end

    # Only tracked divergence errors become resolvable conflicts. Transport and
    # configuration failures must not offer an exclusion of unrelated data.
    def record_conflict(module_key, source_id, error)
      return unless @project_id
      return unless error.message.match?(/Local modification|Local .*modified|Modified source history|Source .*modified|Existing local|Custom field value disappeared/)
      row = MirrorConflict.find_or_initialize_by(project_id: @project_id, connection_key: @connection_key, module_key: module_key, source_id: source_id)
      row.update!(destination_id: find(module_key, source_id)&.fetch("destination_id"), message: error.message, status: "open", checked_at: Time.current)
    end

    def resolve_conflict(module_key, source_id)
      return unless @project_id
      MirrorConflict.where(project_id: @project_id, connection_key: @connection_key, module_key: module_key, source_id: source_id, status: "open").update_all(status: "resolved", checked_at: Time.current, updated_at: Time.current)
    end

    def pending_parent(record, local_issue_id:, status:, reason:)
      return unless @project_id && record["parent"]
      row = MirrorPendingParent.find_or_initialize_by(project_id: @project_id, connection_key: @connection_key, source_id: record.fetch("id"))
      row.update!(local_issue_id: local_issue_id, remote_parent_id: record.fetch("parent").fetch("id"), status: status, reason: reason, checked_at: Time.current)
    end

    def resolve_pending_parent(source_id)
      MirrorPendingParent.where(project_id: @project_id, connection_key: @connection_key, source_id: source_id).delete_all if @project_id
    end

    # Prune diagnostics only after a successful complete source pass. Imported
    # native parent links and issues are never deleted by this cleanup.
    def prune_pending_parents(source_ids)
      MirrorPendingParent.where(project_id: @project_id, connection_key: @connection_key).where.not(source_id: source_ids).delete_all if @project_id
    end

    def pending_relation(record, local_issue_id:, remote_issue_id:, status:, reason:, note_id: nil)
      row = MirrorPendingRelation.find_or_initialize_by(project_id: @project_id, connection_key: @connection_key, source_id: record.fetch("id"))
      row.update!(local_issue_id: local_issue_id, remote_issue_id: remote_issue_id,
        relation_type: record.fetch("relation_type"), delay: record["delay"], status: status,
        reason: reason, note_id: note_id || row.note_id, checked_at: Time.current)
    end

    def prune_pending_relations(source_ids)
      MirrorPendingRelation.where(project_id: @project_id, connection_key: @connection_key).where.not(source_id: source_ids).delete_all
    end

    def resolve_pending_relation(source_id)
      MirrorPendingRelation.where(project_id: @project_id, connection_key: @connection_key, source_id: source_id).delete_all
    end

    # Remote IDs are meaningful only within the same source instance. Reuse a
    # cross-project mapping only when its destination identity is unambiguous.
    def find_related_mapping(module_key, source_id)
      setting = MirrorProjectSetting.find_by!(project_id: @project_id)
      url = setting.source_url.sub(%r{/+\z}, "")
      rows = MirrorProjectSetting.all.filter_map do |candidate|
        next unless candidate.source_url.sub(%r{/+\z}, "") == url
        key = Digest::SHA256.hexdigest(JSON.generate([url, candidate.source_project_id, ENV.fetch("MIRROR_DESTINATION_URL").sub(%r{/+\z}, ""), candidate.project_id]))
        MirrorMapping.find_by(connection_key: key, module_key: module_key, source_id: source_id)
      end
      raise Error, "Ambiguous relation correspondence" if rows.map(&:destination_id).uniq.size > 1
      rows.first&.attributes
    end

    # Validate that the mapped local issue still belongs to its configured project;
    # a moved or deleted endpoint must not silently redirect a relation.
    def resolve_issue(source_id)
      setting = MirrorProjectSetting.find_by(project_id: @project_id)
      raise Error, "Missing project configuration" unless setting
      source_url = setting.source_url.sub(%r{/+\z}, "")
      matches = MirrorProjectSetting.all.filter_map do |candidate|
        next unless candidate.source_url.sub(%r{/+\z}, "") == source_url
        destination = ENV.fetch("MIRROR_DESTINATION_URL").sub(%r{/+\z}, "")
        key = Digest::SHA256.hexdigest(JSON.generate([source_url, candidate.source_project_id, destination, candidate.project_id]))
        row = MirrorMapping.find_by(connection_key: key, module_key: "issue_tracking", source_id: source_id)
        next unless row
        issue = Issue.find_by(id: row.destination_id, project_id: candidate.project_id)
        raise Error, "Destination relation endpoint moved or missing" unless issue
        issue.id
      end.uniq
      raise Error, "Ambiguous issue correspondence" if matches.size > 1
      matches.first
    end

    private

    def scope(module_key, source_id)
      MirrorMapping.where(connection_key: @connection_key, module_key: module_key, source_id: source_id)
    end
  end
end
