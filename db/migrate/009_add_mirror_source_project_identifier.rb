# frozen_string_literal: true
# File: redmine_mirror/db/migrate/009_add_mirror_source_project_identifier.rb
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
class AddMirrorSourceProjectIdentifier < ActiveRecord::Migration[6.1]
  def change
    # Shown in the connection form; the numeric ID remains the correspondence identity.
    add_column :mirror_project_settings, :source_project_identifier, :string, limit: 100
  end
end
