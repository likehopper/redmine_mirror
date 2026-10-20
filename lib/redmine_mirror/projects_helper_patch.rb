# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/projects_helper_patch.rb
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
# Add the "Mirror" and "Mirror source" tabs to the project settings, for members allowed to configure them.

module RedmineMirror
  module ProjectsHelperPatch
    def project_settings_tabs
      tabs = super
      # Redmine filters its tabs by one permission; configuring also follows the
      # right to enable the project's modules (RedmineMirror.manager?).
      if RedmineMirror.manager?(@project)
        tabs << { name: "mirror", action: :manage_mirror, partial: "mirror_settings/configuration", label: :label_mirror }
      end
      if @project&.module_enabled?(:mirror_source) && User.current.allowed_to?(:manage_mirror_source, @project)
        tabs << { name: "mirror_source", action: :manage_mirror_source, partial: "mirror_source_settings/show", label: :label_mirror_source_module }
      end
      tabs
    end
  end
end
