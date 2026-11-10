# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/subprojects.rb
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
# Configure the source subprojects of a project from its Mirror settings.

module RedmineMirror
  # The source subprojects a parent configuration lists (catalog "subprojects", read through
  # Mirror source), each linked to a local subproject: an existing one, or one created with
  # the name and identifier chosen. Each gets the Redmine modules its Mirror modules need,
  # Mirror included, and its own Mirror configuration that takes the parent's connection,
  # options and correspondences (ParentMappings). Only adds: nothing is unlinked or removed.
  class Subprojects
    Result = Struct.new(:linked, :errors)

    def initialize(setting)
      @setting = setting
      @project = setting.project
    end

    # Source subprojects in tree order, with their depth under the source project.
    def rows
      records = Array(@setting.source_catalog["subprojects"])
      depths = { @setting.source_project_id => 0 }
      records.map do |record|
        depth = (depths[record["parent_id"]] || 0) + 1
        depths[record["id"]] = depth
        record.merge("depth" => depth)
      end
    end

    # Child configurations by source project ID.
    def linked
      @linked ||= @setting.child_settings.preload(:project).index_by(&:source_project_id)
    end

    # Local subprojects the person can see, without a Mirror configuration of their own, in
    # tree order.
    # Read again each time: creating a subproject moves the tree bounds (lft, rgt) in the
    # database, not in the project already loaded.
    def candidates
      Project.find(@project.id).descendants.visible.where.not(status: Project::STATUS_ARCHIVED)
        .where.not(id: MirrorProjectSetting.select(:project_id)).order(:lft).to_a
    end

    # The local subproject with the source identifier, else with the same name.
    def default_target(row)
      candidates.find { |project| project.identifier == row["identifier"] } ||
        candidates.find { |project| NameMatch.key(project.name) == NameMatch.key(row["name"]) }
    end

    # The parent's Mirror modules the source subproject can provide.
    def default_modules(row)
      source = Array(row["modules"])
      @setting.adapters.select(&:selectable?).select { |adapter| adapter.source_project_module.nil? || source.include?(adapter.source_project_module.to_s) }.map(&:key)
    end

    # input: { "<source id>" => { "include" => "1", "target" => "new" or a local project ID,
    # "name" => ..., "identifier" => ..., "modules" => [...] } }. Each row is saved on its own:
    # a refused row leaves the others.
    def apply(input, user)
      result = Result.new([], [])
      local = { @setting.source_project_id => @project }
      linked.each { |source_id, child| local[source_id] = child.project }
      rows.each do |row|
        entry = input[row["id"].to_s]
        next unless entry.is_a?(Hash) && entry["include"] == "1" && !linked.key?(row["id"])
        parent = local[row["parent_id"]]
        next result.errors << [row["name"], ::I18n.t(:text_mirror_subproject_parent_missing)] unless parent
        project = nil
        Project.transaction do
          project = entry["target"] == "new" ? create_project(row, entry, parent, user) : existing_project(entry["target"], user)
          modules = Array(entry["modules"]).map(&:to_s) & default_modules(row)
          raise Error, ::I18n.t(:text_mirror_nothing_left_to_import) if modules.empty?
          child = build_child(project, row, modules)
          (["mirror"] + child.adapters.map(&:project_module).compact.map(&:to_s)).uniq.each { |name| project.enable_module!(name) }
          child.save!
          child.request_catalog_refresh!
        end
        local[row["id"]] = project
        result.linked << project
      rescue Error, ActiveRecord::RecordInvalid => error
        result.errors << [row["name"], error.message]
      end
      result
    end

    private

    def create_project(row, entry, parent, user)
      raise Error, ::I18n.t(:text_mirror_subproject_create_denied, project: parent.name) unless user.allowed_to?(:add_subprojects, parent)
      name = entry["name"].to_s.strip.presence || row["name"]
      # As in Redmine's form, choosing a new project's modules needs the creator's role to.
      unless user.admin? || Project.default_member_role&.has_permission?(:select_project_modules)
        raise Error, ::I18n.t(:text_mirror_subproject_modules_denied, project: name)
      end
      # Private: the source subproject may be private, whatever its local parent is.
      project = Project.new(name: name, identifier: entry["identifier"].to_s.strip.presence || row["identifier"], is_public: false, inherit_members: false)
      project.parent = parent
      project.save!
      # As Redmine does for a project created by someone who is not an administrator.
      project.add_default_member(user) unless user.admin?
      project
    end

    # Only a subproject of this project without a Mirror configuration (candidates).
    def existing_project(target, user)
      project = candidates.find { |candidate| candidate.id.to_s == target.to_s }
      raise Error, ::I18n.t(:text_mirror_subproject_unknown_target) unless project
      raise Error, ::I18n.t(:text_mirror_subproject_modules_denied, project: project.name) unless user.allowed_to?(:select_project_modules, project)
      project
    end

    # The parent's connection (same source, same key), options and choices.
    def build_child(project, row, modules)
      child = MirrorProjectSetting.new(project: project, parent_setting: @setting, source_url: @setting.source_url,
        source_project_id: row["id"], source_project_identifier: row["identifier"], source_text_format: @setting.source_text_format,
        on_error: @setting.on_error, use_default_mappings: @setting.use_default_mappings)
      child[:encrypted_api_key] = @setting[:encrypted_api_key]
      child[:module_options] = @setting[:module_options]
      child.selected_modules = modules
      child
    end
  end
end
