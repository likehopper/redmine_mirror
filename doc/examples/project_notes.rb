# frozen_string_literal: true
# File: redmine_mirror/doc/examples/project_notes.rb
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

# Copy this file to lib/redmine_mirror/adapters/project_notes.rb before registering it.
# The notes API is fictional: both instances must implement the contract in ADAPTERS.md.
# Keeping this example outside lib prevents accidental activation in real projects.
module RedmineMirror
  module Adapters
    class ProjectNotes < Base
      def key; "project_notes"; end
      def collection; "project_notes"; end
      def entity; "project_note"; end

      # Only these destination fields participate in local modification detection.
      # Server-generated IDs and timestamps must not affect this fingerprint.
      def fields; %w[title body]; end

      # Use the destination project ID, never the source record's project reference.
      # The remaining parameters support mappings and dependent object lookups.
      def payload(record, project_id, _mappings, _lookup, options: {})
        record.slice("title", "body").merge("project_id" => project_id)
      end
    end
  end
end
