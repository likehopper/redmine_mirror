# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_admin_controller.rb
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
# Administration overview: the projects Mirror is configured in, their activity and load.

class MirrorAdminController < ApplicationController
  layout "admin"
  self.main_menu = false
  menu_item :mirror_admin
  before_action :require_admin
  before_action :require_migrated_schema

  helper :queries
  include QueriesHelper
  helper MirrorHelper

  def index
    retrieve_query(MirrorProjectQuery, false)
    return unless @query.valid?
    respond_to do |format|
      format.html do
        @setting_count = @query.base_scope.count
        @setting_pages = Paginator.new(@setting_count, per_page_option, params["page"])
        @settings = @query.results(offset: @setting_pages.offset, limit: @setting_pages.per_page)
      end
      format.csv do
        send_data(query_to_csv(@query.results, @query, params), type: "text/csv; header=present", filename: "mirror-projects.csv")
      end
    end
  rescue Query::StatementInvalid
    render_error status: 500
  end

  private

  def require_migrated_schema
    return if MirrorProjectSetting.schema_current? && MirrorSyncRun.column_names.include?("duration_seconds")
    render_error message: l(:text_mirror_pending_migrations), status: 503
  end
end
