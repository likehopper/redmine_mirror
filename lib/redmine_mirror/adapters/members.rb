# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/members.rb
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
# Add source project members and their roles to existing local users and groups.

module RedmineMirror
  # With the Members option "unmapped: skip", roles and groups left without a mapping are
  # not given instead of blocking their members, and the tab counter leaves them out.
  module MembersOptionalMapping
    def unmapped_allowed?(setting)
      setting.module_options.dig("project_members", "unmapped") == "skip"
    end
  end

  # Source roles map to local givable roles; an ignored role is not given.
  class RoleMappingTable < MappingTable
    include MembersOptionalMapping
    def initialize; super("role", reference_fields: []); end
    def ignore_allowed?; true; end
    def ignore_label; :label_mirror_ignore_role; end
    def local_records(_project); Role.givable.sorted; end
    def references(record); Adapters::Members.own_roles(record); end
    def local_path(id, _project); "/roles/#{Integer(id)}/edit"; end
    def remote_path(id, _setting); "roles/#{Integer(id)}/edit"; end
  end

  # Source groups map to existing local groups; Mirror never creates a group.
  class GroupMappingTable < MappingTable
    include MembersOptionalMapping
    def initialize; super("group"); end
    def ignore_allowed?; true; end
    def ignore_label; :label_mirror_ignore_group; end
    def local_records(_project); Group.givable.sorted; end
    def local_path(id, _project); "/groups/#{Integer(id)}/edit"; end
    def remote_path(id, _setting); "groups/#{Integer(id)}"; end
  end

  module Adapters
    # Additive: members and roles are added, never removed. A role Mirror gave and that
    # was removed locally while the source still lists it is a conflict. When the source
    # wins, a member's own roles are exactly the mapped source roles.
    class Members < Base
      def key; "project_members"; end
      def phase; :references; end
      def dependencies; ["users"]; end
      def mapping_tables; [RoleMappingTable.new, GroupMappingTable.new]; end
      def referenced_users(record); [record["user"]].compact; end

      # Roles inherited from a group or a parent project come with that group or project.
      def self.own_roles(record)
        record.fetch("roles", []).reject { |role| role["inherited"] }
      end

      def records(client, project_id)
        Enumerator.new do |output|
          offset = 0
          loop do
            page = client.get("projects/#{Integer(project_id)}/memberships.json", "offset" => offset, "limit" => 100)
            rows = page.fetch("memberships")
            raise Error, "Invalid API collection" unless rows.is_a?(Array)
            rows.each { |row| output << row }
            offset += rows.size
            break if rows.empty? || offset >= Integer(page.fetch("total_count"))
          end
        end
      end

      UNMAPPED = %w[block skip].freeze

      def configuration_options(input, _project)
        value = input.fetch("unmapped", "block")
        raise Error, "Invalid unmapped roles policy" unless UNMAPPED.include?(value)
        { "unmapped" => value }
      end

      def local_path(_id, project); "/projects/#{project.identifier}/settings/members"; end

      def remote_path(_id, setting)
        "projects/#{setting.source_project_identifier.presence || setting.source_project_id}/settings/members"
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        @skip_unmapped = project.mirror_project_setting&.module_options&.dig(key, "unmapped") == "skip"
        event = { module: key, source_id: record.fetch("id"), destination_id: nil, action: "update" }
        principal_id = record["user"] ? Users.new.resolve(mappings, record["user"].fetch("id")) : optional_map(mappings, "group", record.fetch("group").fetch("id"))
        return event.merge(action: "ignored", reason: "Anonymized user or ignored group") unless principal_id
        roles = self.class.own_roles(record).filter_map { |role| optional_map(mappings, "role", role.fetch("id")) }.uniq.sort
        return event.merge(action: "ignored", reason: "No role to give: inherited or ignored roles only") if roles.empty?
        principal = Principal.find_by(id: principal_id)
        unless (principal.is_a?(User) && (principal.active? || principal.locked?)) || (principal.is_a?(Group) && principal.givable?)
          raise Error, "Mapped member ##{principal_id} must be an active or locked user, or a group"
        end
        member = project.memberships.find_by(user_id: principal.id)
        current = own_role_ids(member)
        previous = store.find(key, record.fetch("id"))
        if !Policy.source_wins? && previous && previous.fetch("source_fingerprint") == digest(roles) && digest(roles & current) != previous.fetch("destination_fingerprint")
          raise Error, "Local modification detected for project_members: a role given from the source was removed locally from #{principal.name}"
        end
        target = Policy.source_wins? ? roles : (current + roles).uniq.sort
        event[:destination_id] = member&.id
        event[:action] = member ? (target == current ? "unchanged" : "update") : "create"
        if apply
          MirrorMapping.transaction do
            member ||= Member.new(project: project, principal: principal)
            # role_ids= keeps the roles inherited from groups and parent projects.
            member.role_ids = target unless target == current
            member.save!
            store.save(key, record.fetch("id"), "destination_id" => member.id,
              "source_fingerprint" => digest(roles), "destination_fingerprint" => digest(roles & own_role_ids(member.reload)))
          end
          event[:destination_id] = member.id
        end
        event
      end

      def source_state(client, source_id, _destination_id, source_project_id:, project_id:)
        remote_state(client, "memberships/#{Integer(source_id)}.json")
      end

      def delete_local(destination_id, project_id)
        Member.where(project_id: project_id).find_by(id: destination_id)&.destroy
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      def own_role_ids(member)
        member ? member.member_roles.select { |row| row.inherited_from.nil? }.map(&:role_id).uniq.sort : []
      end

      # nil when the reference is ignored, or left unmapped with the "skip" option.
      def optional_map(mappings, kind, source_id)
        value = mappings.fetch(kind, {})[source_id.to_s]
        return nil if value == "ignore" || (value.nil? && @skip_unmapped)
        map(mappings, kind, source_id)
      end
    end
  end
end
