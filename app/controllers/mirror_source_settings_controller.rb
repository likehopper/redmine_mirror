# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_source_settings_controller.rb
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
# Save what the project shares with Mirror destinations (Mirror source tab).

class MirrorSourceSettingsController < ApplicationController
  include RedmineMirror::PlainFlash
  before_action :find_project_by_project_id
  before_action :authorize

  def update
    setting = @project.mirror_source_setting || @project.build_mirror_source_setting
    # Data the administrator does not allow is not in the form: it keeps its saved choice,
    # back in effect if the administrator allows it again.
    allowed = RedmineMirror::Source.allowed_kinds
    setting.shared_modules = (Array(params.fetch(:shared_modules, [])).map(&:to_s) & allowed) | (setting.shared_modules - allowed)
    setting.save!
    flash[:notice] = l(:notice_successful_update)
    redirect_to settings_project_path(@project, tab: "mirror_source")
  end

  # Give each subproject this project's sharing: Mirror source enabled, and the same data
  # among those its own modules hold. Only where the person may enable the modules
  # (Select project modules) and configure Mirror source; the others are counted. A later
  # change here reaches the subprojects only when applied again.
  def apply_to_subprojects
    shared = @project.mirror_source_setting&.shared_modules.to_a
    done = []
    skipped = 0
    @project.descendants.where.not(status: Project::STATUS_ARCHIVED).visible.order(:lft).each do |child|
      Project.transaction do
        raise ActiveRecord::Rollback unless User.current.allowed_to?(:select_project_modules, child)
        child.enable_module!(:mirror_source)
        child.reload
        raise ActiveRecord::Rollback unless User.current.allowed_to?(:manage_mirror_source, child)
        setting = child.mirror_source_setting || child.build_mirror_source_setting
        setting.shared_modules = shared - RedmineMirror::Source.kinds_without_module(child)
        setting.save!
        done << child
      end
      skipped += 1 unless done.include?(child)
    end
    flash[:notice] = l(:text_mirror_source_applied_to_subprojects, count: done.size, skipped: skipped)
    redirect_to settings_project_path(@project, tab: "mirror_source")
  end
end
