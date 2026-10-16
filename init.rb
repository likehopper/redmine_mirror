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
require_relative "lib/redmine_mirror"
require_relative "lib/redmine_mirror/hooks"
Redmine::Plugin.register :redmine_mirror do
  name "Redmine Mirror"
  author "LikeHopper and Redmine Mirror contributors"
  author_url "https://github.com/likehopper"
  url "https://github.com/likehopper/redmine_mirror"
  description "Modular project synchronization through Redmine REST APIs"
  version RedmineMirror::VERSION
  requires_redmine version_or_higher: "5.0"
  project_module :mirror do
    permission :manage_mirror, { mirror_conflicts: [:update], mirror_synchronizations: [:update, :create, :show], mirror_settings: [:show, :update_connection, :update_mappings, :refresh] }, require: :member
    permission :view_mirror, { mirror: [:index] }, require: :member
  end
  menu :project_menu, :mirror, { controller: "mirror", action: "index" },
       caption: :label_mirror, param: :project_id
end

Project.include(RedmineMirror::ProjectPatch) unless Project < RedmineMirror::ProjectPatch
Rails.application.config.filter_parameters += [:api_key, :encrypted_api_key]
