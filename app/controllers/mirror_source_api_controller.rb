# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_source_api_controller.rb
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
# Mirror source API: read-only data Redmine's REST API lacks, served only when the
# administrator, the project and its sharing allow it, and logged request by request.

class MirrorSourceApiController < ApplicationController
  accept_api_auth :documents, :document, :news, :news_item, :download
  before_action :find_project_by_project_id, only: %i[documents news]
  before_action :find_document, only: :document
  before_action :find_news, only: :news_item
  before_action :find_attachment, only: :download
  before_action :check_access

  helper :attachments
  helper :custom_fields
  helper :mirror_source_api

  def documents
    @documents = @project.documents.preload(:category, attachments: :author).order(:id).to_a
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @documents.size,
      details: { "documents" => @documents.map { |document| { "id" => document.id, "title" => document.title, "files" => document.attachments.size } } })
    respond_to { |format| format.api }
  end

  def document
    RedmineMirror::Source.log(@project, request, User.current, "show", object_count: 1,
      details: { "documents" => [{ "id" => @document.id, "title" => @document.title }] })
    respond_to { |format| format.api }
  end

  # Every news item of the project, with its comments and files.
  def news
    @news = @project.news.preload(:author, comments: :author, attachments: :author).order(:id).to_a
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @news.size,
      details: { "news" => @news.map { |item| { "id" => item.id, "title" => item.title, "comments" => item.comments.size, "files" => item.attachments.size } } })
    respond_to { |format| format.api }
  end

  def news_item
    RedmineMirror::Source.log(@project, request, User.current, "show", object_count: 1,
      details: { "news" => [{ "id" => @news_item.id, "title" => @news_item.title }] })
    respond_to { |format| format.api }
  end

  # Shared files go through here, not the attachments API, so that sharing applies
  # and the transfer is logged.
  def download
    unless File.readable?(@attachment.diskfile)
      render_404
      return
    end
    RedmineMirror::Source.log(@project, request, User.current, "download", object_count: 1, bytes: @attachment.filesize,
      details: { "attachment" => { "id" => @attachment.id, "filename" => @attachment.filename,
        "#{@attachment.container_type.underscore}_id" => @attachment.container_id } })
    send_file @attachment.diskfile, filename: @attachment.filename, type: @attachment.content_type.presence || "application/octet-stream",
      disposition: "attachment"
  end

  private

  def find_document
    @document = Document.find(params[:id])
    @project = @document.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_news
    @news_item = News.find(params[:id])
    @project = @news_item.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # Only the files of shareable data: documents and news.
  def find_attachment
    @attachment = Attachment.find(params[:id])
    return render_404 unless RedmineMirror::Source::CONTAINERS.key?(@attachment.container_type)
    @project = @attachment.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def kind
    case action_name
    when "news", "news_item" then "news"
    when "download" then RedmineMirror::Source::CONTAINERS.fetch(@attachment.container_type)
    else "documents"
    end
  end

  # An account is required, even on public projects. Projects it cannot see are
  # refused without any detail. Otherwise the refusal header names the lock to open,
  # and the attempt is logged.
  def check_access
    return require_login unless User.current.logged?
    return deny_access unless @project.visible?
    reason = RedmineMirror::Source.refusal(@project, kind, User.current)
    return unless reason
    RedmineMirror::Source.log(@project, request, User.current, "refused", reason: reason, details: { "path" => request.path })
    response.headers[RedmineMirror::Source::REFUSAL_HEADER] = reason
    deny_access
  end
end
