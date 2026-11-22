# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/parent_mappings.rb
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
# Give a subproject its parent's correspondences.

module RedmineMirror
  # A subproject configured from its parent (Subprojects) has the same source Redmine, hence
  # the same source IDs for trackers, statuses, users or fields: each source reference it has
  # no correspondence for takes the parent's, once its references are read. Its own choices
  # stay and override the parent's.
  # With replace, the parent's correspondences and module options also overwrite the
  # subproject's own ones (an action of the parent's Subprojects section).
  module ParentMappings
    module_function

    # Returns the number of correspondences saved.
    def apply(setting, replace: false)
      parent = setting.parent_setting
      return 0 unless parent
      project = setting.project
      catalog = setting.source_catalog
      existing = project.mirror_reference_mappings.index_by { |row| [row.reference_type, row.source_id.to_s] }
      setting.update!(module_options: parent.module_options) if replace
      parent.project.mirror_reference_mappings.to_a.count do |row|
        own = existing[[row.reference_type, row.source_id.to_s]]
        next false if own && !replace
        next false unless catalog.fetch(row.reference_type, {}).key?(row.source_id.to_s)
        target = own || MirrorReferenceMapping.new(project: project, reference_type: row.reference_type, source_id: row.source_id)
        target.assign_attributes(mode: row.mode, destination_id: row.destination_id)
        # A destination the subproject refuses (a field it does not use) stays to map by hand.
        target.changed? && target.save
      end
    end
  end
end
