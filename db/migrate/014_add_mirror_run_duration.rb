# frozen_string_literal: true
# File: redmine_mirror/db/migrate/014_add_mirror_run_duration.rb
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

class AddMirrorRunDuration < ActiveRecord::Migration[RedmineMirror.migration_version]
  class Run < ActiveRecord::Base
    self.table_name = "mirror_sync_runs"
  end

  # Seconds between start and end, stored so that every database sums and sorts them
  # the same way (administration overview).
  def up
    add_column :mirror_sync_runs, :duration_seconds, :integer
    Run.reset_column_information
    Run.where.not(started_at: nil).where.not(finished_at: nil).find_each do |run|
      run.update_columns(duration_seconds: [(run.finished_at - run.started_at).round, 0].max)
    end
  end

  def down
    remove_column :mirror_sync_runs, :duration_seconds
  end
end
