# frozen_string_literal: true
# File: redmine_mirror/db/migrate/010_add_mirror_source_text_format.rb
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
class AddMirrorSourceTextFormat < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    # auto, textile, markdown or html: how source texts are read before conversion.
    add_column :mirror_project_settings, :source_text_format, :string, limit: 20, null: false, default: "auto"
  end
end
