# frozen_string_literal: true
# File: redmine_mirror/app/helpers/mirror_source_api_helper.rb
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
# Render documents and news like Redmine's own API resources, files included.

module MirrorSourceApiHelper
  def render_api_mirror_document(document, api)
    api.id document.id
    api.project(id: document.project_id, name: document.project.name)
    api.category(id: document.category_id, name: document.category&.name)
    api.title document.title
    api.description document.description
    api.created_on document.created_on
    render_api_custom_values document.visible_custom_field_values, api
    api.array :attachments do
      document.attachments.each { |attachment| render_api_attachment(attachment, api) }
    end
  end

  def render_api_mirror_news(news, api)
    api.id news.id
    api.project(id: news.project_id, name: news.project.name)
    api.author(id: news.author_id, name: news.author.name) if news.author
    api.title news.title
    api.summary news.summary
    api.description news.description
    api.created_on news.created_on
    api.array :comments do
      news.comments.each do |comment|
        api.comment do
          api.id comment.id
          api.author(id: comment.author_id, name: comment.author.name) if comment.author
          api.content comment.comments
          api.created_on comment.created_on
          api.updated_on comment.updated_on
        end
      end
    end
    api.array :attachments do
      news.attachments.each { |attachment| render_api_attachment(attachment, api) }
    end
  end
end
