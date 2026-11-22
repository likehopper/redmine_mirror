# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_source_controller.rb
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
# Project Mirror source operations: filter and group the access log.

class MirrorSourceController < ApplicationController
  PER_PAGE = 50

  before_action :find_project_by_project_id
  before_action :authorize
  before_action :require_migrated_schema

  helper MirrorHelper

  def index
    base = @project.mirror_source_accesses
    @accounts = User.where(id: base.where.not(user_id: nil).distinct.pluck(:user_id)).sorted.to_a
    @addresses = base.where.not(remote_ip: [nil, ""]).distinct.order(:remote_ip).pluck(:remote_ip)
    @group_by = %w[session destination].include?(params[:group_by]) ? params[:group_by] : "session"
    @session_key = params[:session].to_s

    if @session_key.match?(RedmineMirror::Source::SESSION)
      @accesses = session_accesses(base).order(:created_at, :id).preload(:user).to_a
      return
    end

    scope = filtered(base)
    grouped = @group_by == "destination" ? scope.destinations : scope.sessions
    grouped = grouped.having("SUM(CASE WHEN action = 'refused' THEN 1 ELSE 0 END) > 0") if params[:refused] == "1"
    @row_count = MirrorSourceAccess.group_count(grouped)
    @pages = Paginator.new(@row_count, PER_PAGE, params[:page])
    @rows = grouped.offset(@pages.offset).limit(@pages.per_page).to_a
  end

  private

  def filtered(scope)
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope = scope.where(remote_ip: params[:remote_ip]) if params[:remote_ip].present?
    scope = scope.where(purpose: params[:purpose]) if RedmineMirror::Source::PURPOSES.include?(params[:purpose])
    scope
  end

  def session_accesses(scope)
    scope = scope.where(session_key: @session_key)
    scope = scope.where(user_id: params[:user_id]) if params.key?(:user_id)
    scope = scope.where(remote_ip: params[:remote_ip]) if params.key?(:remote_ip)
    scope = scope.where(purpose: params[:purpose] == "-" ? nil : params[:purpose]) if params.key?(:purpose)
    scope
  end

  def require_migrated_schema
    return if MirrorSourceAccess.table_exists? && MirrorSourceSetting.client_schema_current?
    render_error message: l(:text_mirror_pending_migrations), status: 503
  end
end
