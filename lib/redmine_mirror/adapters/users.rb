# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/users.rb
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
# Resolve shared identity mappings without creating users or bypassing project membership.

module RedmineMirror
  module Adapters
    # Shared reference adapter: resolves identities without creating remote accounts.
    class Users < Base
      def key; "users"; end
      def selectable?; false; end
      def mapping_tables; [MappingTable.new("user", reference_fields: [])]; end
      def records(_client, _project_id); []; end
      def anonymous_time_user_required?; true; end

      # Time entries require a real user even when the remote identity is anonymized.
      # The dedicated account must already be an active destination project member.
      def configuration_options(input, project)
        value = input["anonymous_user_id"]
        return {} if value.nil? || value.to_s.empty?
        destination_user_id = Integer(value)
        raise Error, "Anonymous time user must be an active project member" unless project.users.active.exists?(id: destination_user_id)
        { "anonymous_user_id" => destination_user_id }
      rescue ArgumentError, TypeError
        raise Error, "Invalid anonymous time user"
      end

      # Optional anonymous references become nil; callers decide whether this means
      # no assignee, an empty value or the native anonymous historical author.
      def resolve(mappings, source_id, required: false, options: {})
        value = mappings.fetch("user", {}).fetch(source_id.to_s) do
          raise Error, "Missing user mapping for source ID #{source_id}"
        end
        if value == "anonymous"
          return nil unless required
          value = options["anonymous_user_id"]
          raise Error, "Configure a local user for anonymized time entries" unless value
        end
        destination_user_id = Integer(value)
        raise Error, "Invalid user mapping" unless destination_user_id.positive?
        destination_user_id
      rescue ArgumentError, TypeError
        raise Error, "Invalid user mapping"
      end
    end
  end
end
