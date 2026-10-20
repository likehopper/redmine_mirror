# frozen_string_literal: true
# File: redmine_mirror/init.rb
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
# Register project permissions, navigation and native Redmine integration.

require "redmine"
# Require through the plugin path Redmine uses, not the symlink-resolved path of
# require_relative: a plugin directory linked from elsewhere would be loaded twice.
require File.join(File.dirname(__FILE__), "lib/redmine_mirror")
require File.join(File.dirname(__FILE__), "lib/redmine_mirror/hooks")
Redmine::Plugin.register :redmine_mirror do
  name "Redmine Mirror"
  author "LikeHopper and Redmine Mirror contributors"
  author_url "https://github.com/likehopper"
  url "https://github.com/likehopper/redmine_mirror"
  description "Modular project synchronization through Redmine REST APIs"
  version RedmineMirror::VERSION
  requires_redmine version_or_higher: "5.0"
  # The project settings hold the configuration (manage_mirror); the Mirror menu shows
  # the operations: status and history (view_mirror), launching executions and
  # resolving conflicts (run_mirror). Configuring includes the other two, and the right
  # to enable the project's modules includes configuring (RedmineMirror.manager?).
  project_module :mirror do
    permission :view_mirror, { mirror: [:index], mirror_synchronizations: [:show] }, read: true, require: :member
    permission :run_mirror, { mirror: [:index], mirror_synchronizations: [:show, :create, :cancel], mirror_conflicts: [:update] }, require: :member
    permission :manage_mirror, { projects: [:settings], mirror: [:index], mirror_synchronizations: [:show, :create, :cancel, :update],
      mirror_conflicts: [:update], mirror_settings: [:show, :update_connection, :update_mappings, :refresh, :request_ai] }, require: :member
  end
  # Mirror source, when this Redmine is a source: a project shares chosen data with Mirror
  # destinations (Documents), if an administrator allows it. Configuring the sharing
  # and reading its access log are one permission; the API account needs only the
  # native permission of the data (View documents).
  project_module :mirror_source do
    permission :manage_mirror_source, { projects: [:settings], mirror_source_settings: [:update] }, require: :member
  end
  # Administrators list the source Redmine URLs that project managers may connect to,
  # and allow Mirror source globally (off by default).
  settings default: { "allowed_source_urls" => "", "user_company_field_id" => "", "source_enabled" => "", "source_log_days" => "180" },
    partial: "settings/redmine_mirror"
  menu :project_menu, :mirror, { controller: "mirror", action: "index" },
       caption: :label_mirror, param: :project_id
  # Administration overview of the projects Mirror is configured in.
  menu :admin_menu, :mirror_admin, { controller: "mirror_admin", action: "index" },
       caption: :label_mirror_admin, html: { class: "icon icon-mirror-admin" }
end

Project.include(RedmineMirror::ProjectPatch) unless Project < RedmineMirror::ProjectPatch
# The settings tab is added by a helper of ProjectsController, not by patching
# ProjectsHelper: plugins that chain project_settings_tabs with alias_method would
# capture a prepended method and break its call to super.
ProjectsController.helper(MirrorHelper) unless ProjectsController._helpers < MirrorHelper
ProjectsController.helper(RedmineMirror::ProjectsHelperPatch) unless ProjectsController._helpers < RedmineMirror::ProjectsHelperPatch
Rails.application.config.filter_parameters += [:api_key, :encrypted_api_key]
