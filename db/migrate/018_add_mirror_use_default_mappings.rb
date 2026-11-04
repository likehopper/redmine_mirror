# frozen_string_literal: true
# File: redmine_mirror/db/migrate/018_add_mirror_use_default_mappings.rb
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

class AddMirrorUseDefaultMappings < ActiveRecord::Migration[RedmineMirror.migration_version]
  # Each project chooses whether the administrator's default correspondences fill it.
  def change
    add_column :mirror_project_settings, :use_default_mappings, :boolean, null: false, default: true
  end
end
