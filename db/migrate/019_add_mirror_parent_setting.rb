# frozen_string_literal: true
# File: redmine_mirror/db/migrate/019_add_mirror_parent_setting.rb
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
# Apply or revert this versioned Mirror database schema change.

class AddMirrorParentSetting < ActiveRecord::Migration[RedmineMirror.migration_version]
  # A subproject configured from its parent's Mirror settings: it takes the parent's
  # connection and correspondences, and runs after it.
  def change
    add_column :mirror_project_settings, :parent_setting_id, :integer
    add_index :mirror_project_settings, :parent_setting_id
  end
end
