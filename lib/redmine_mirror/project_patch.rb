# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/project_patch.rb
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
# Attach Mirror configuration and diagnostic associations to Redmine projects.

module RedmineMirror
  module ProjectPatch
    def self.included(base)
      base.has_many :mirror_pending_parents, dependent: :destroy
      base.has_many :mirror_conflicts, dependent: :destroy
      base.has_many :mirror_pending_relations, dependent: :destroy
      base.has_many :mirror_sync_runs, dependent: :destroy
      base.has_one :mirror_project_setting, dependent: :destroy
      base.has_many :mirror_reference_mappings, dependent: :destroy
    end
  end
end
