# frozen_string_literal: true
# File: redmine_mirror/db/migrate/012_add_mirror_catalog_status.rb
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
class AddMirrorCatalogStatus < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    # The worker refreshes source references: ready, pending, refreshing or failed.
    add_column :mirror_project_settings, :catalog_status, :string, limit: 12, null: false, default: "ready"
    add_column :mirror_project_settings, :catalog_requested_at, :datetime
    add_column :mirror_project_settings, :catalog_error, :text
    # JSON progress of the refresh in progress: step, module and records read.
    add_column :mirror_project_settings, :catalog_progress, :text
  end
end
