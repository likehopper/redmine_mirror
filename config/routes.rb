# frozen_string_literal: true
# File: redmine_mirror/config/routes.rb
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
# Define project-scoped Mirror endpoints with explicit HTTP methods.

get "projects/:project_id/mirror", to: "mirror#index", as: "project_mirror"

get "projects/:project_id/mirror/settings", to: "mirror_settings#show", as: "project_mirror_settings"
patch "projects/:project_id/mirror/settings/connection", to: "mirror_settings#update_connection", as: "project_mirror_connection"
post "projects/:project_id/mirror/settings/refresh", to: "mirror_settings#refresh", as: "project_mirror_refresh"
patch "projects/:project_id/mirror/settings/modules/:module_key", to: "mirror_settings#update_mappings", as: "project_mirror_mappings"

patch "projects/:project_id/mirror/schedule", to: "mirror_synchronizations#update", as: "project_mirror_schedule"
post "projects/:project_id/mirror/synchronizations", to: "mirror_synchronizations#create", as: "project_mirror_enqueue"
get "projects/:project_id/mirror/synchronizations/:id", to: "mirror_synchronizations#show", as: "project_mirror_run"
patch "projects/:project_id/mirror/synchronizations/:id/cancel", to: "mirror_synchronizations#cancel", as: "project_mirror_run_cancel"

patch "projects/:project_id/mirror/conflicts/:id", to: "mirror_conflicts#update", as: "project_mirror_conflict"
