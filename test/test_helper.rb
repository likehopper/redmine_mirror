# frozen_string_literal: true
# File: redmine_mirror/test/test_helper.rb
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
# Verify Mirror behavior, project boundaries and repeatable synchronization.

# Tests run from the Redmine root; __dir__ would resolve a symlinked plugin directory.
require File.expand_path("test/test_helper", Dir.pwd)

# The Project Enumerations plugin is not installed here: a minimal model stands for it.
module MirrorFakeProjectEnumerations
  def install_fake_project_enumerations
    connection = ActiveRecord::Base.connection
    connection.create_table(:project_enumerations) do |t|
      t.integer :project_id, null: false
      t.integer :custom_field_id, null: false
      t.string :value
      t.string :status, default: "open"
      t.string :sharing, default: "none", null: false
      t.integer :position
    end
    Object.const_set(:ProjectEnumeration, Class.new(ActiveRecord::Base) do
      self.table_name = "project_enumerations"
      belongs_to :project
      belongs_to :custom_field
      validates :value, presence: true, uniqueness: { scope: :project_id }
    end)
  end

  def remove_fake_project_enumerations
    Object.send(:remove_const, :ProjectEnumeration) if Object.const_defined?(:ProjectEnumeration)
    ActiveRecord::Base.connection.drop_table(:project_enumerations, if_exists: true)
  end

  # Redmine refuses an unknown field format: create a list field, then switch it.
  def enumeration_field(name)
    field = IssueCustomField.create!(name: name, field_format: "list", possible_values: ["x"], is_for_all: true, trackers: Tracker.all)
    field.update_columns(field_format: "project_enumeration", possible_values: nil)
    IssueCustomField.find(field.id)
  end
end
