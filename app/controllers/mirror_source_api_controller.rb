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
  accept_api_auth :documents, :document, :news, :news_item, :issue_tags, :scrum, :queries, :users, :issue_categories,
    :project_enumerations, :project_enumeration, :repositories, :repository_links, :download, :localized_names, :subprojects
  # Once Redmine knows the user, before anything else, the project lookup included: the
  # caller's address and API key.
  before_action :check_caller
  before_action :find_project_by_project_id, only: %i[documents news issue_tags scrum queries users issue_categories project_enumerations repositories localized_names subprojects]
  before_action :find_document, only: :document
  before_action :find_news, only: :news_item
  before_action :find_attachment, only: :download
  # A missing plugin first: its permissions do not exist either.
  before_action :check_plugin, only: %i[issue_tags scrum project_enumerations project_enumeration]
  before_action :find_project_enumeration, only: :project_enumeration
  before_action :find_repository, only: :repository_links
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

  # The subprojects, at any depth, that this account can see and that run Mirror source
  # themselves, with their modules: a project that did not enable Mirror source is never
  # listed. Redmine 4.0's projects API can neither filter by parent nor list modules.
  def subprojects
    table = Project.table_name
    @subprojects = Project.visible.where("#{table}.lft > ? AND #{table}.rgt < ?", @project.lft, @project.rgt)
      .preload(:enabled_modules).order("#{table}.lft").to_a.select { |child| child.module_enabled?(:mirror_source) }
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @subprojects.size,
      details: { "subprojects" => @subprojects.map { |child| { "id" => child.id, "identifier" => child.identifier } } })
    respond_to { |format| format.api }
  end

  def news_item
    RedmineMirror::Source.log(@project, request, User.current, "show", object_count: 1,
      details: { "news" => [{ "id" => @news_item.id, "title" => @news_item.title }] })
    respond_to { |format| format.api }
  end

  # The current tags of every issue of the project the account can see, empty lists
  # included, so that a destination also learns which tags were removed.
  def issue_tags
    scope = Issue.visible.where(project_id: @project.id)
    ids = scope.order(:id).pluck(:id)
    names = scope.joins(:tags).pluck(:id, "#{RedmineCrm::Tag.table_name}.name").group_by(&:first)
    @issue_tags = ids.map { |id| [id, names.fetch(id, []).map(&:last).sort] }
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @issue_tags.size,
      details: { "issue_tags" => { "issues" => @issue_tags.count { |_, tags| tags.any? }, "tags" => @issue_tags.flat_map(&:last).uniq.size } })
    respond_to { |format| format.api }
  end

  # The project's Scrum sprints and product backlogs, and the sprint, backlog position
  # and story points of every visible issue of the project that has one of them.
  def scrum
    @sprints = ::Sprint.where(project_id: @project.id).order(:id).to_a
    issues = Issue.visible.where(project_id: @project.id)
    field_id = (Scrum::Setting.story_points_custom_field_id if defined?(Scrum::Setting)).presence
    points = field_id ? CustomValue.where(custom_field_id: field_id, customized_type: "Issue", customized_id: issues.select(:id))
      .where.not(value: [nil, ""]).pluck(:customized_id, :value).to_h : {}
    # Ruby 2.6 (Redmine 4): no filter_map on the source side.
    @scrum_issues = issues.order(:id).pluck(:id, :sprint_id, :position).map do |id, sprint_id, position|
      [id, sprint_id, position, points[id]] if sprint_id || position || points[id]
    end.compact
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @sprints.size + @scrum_issues.size,
      details: { "scrum" => { "sprints" => @sprints.size, "issues" => @scrum_issues.size } })
    respond_to { |format| format.api }
  end

  # The project's saved queries of issues, time entries and agile boards, private ones
  # included: sharing them is the project's explicit choice, and every list is logged.
  def queries
    types = RedmineMirror::Source::QUERY_TYPES.select { |type| Object.const_defined?(type) }
    @queries = Query.where(project_id: @project.id, type: types).preload(:user, :roles).order(:id).to_a
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @queries.size,
      details: { "queries" => @queries.map { |query| { "id" => query.id, "title" => "#{query.name} (#{query.type})" } } })
    respond_to { |format| format.api }
  end

  # Login, names, email and company of the requested users (?ids=1,2) who are members of
  # the project or appear in its data; the others are left out without a word. Redmine's
  # users API gives logins and emails to administrators only.
  def users
    ids = params[:ids].to_s.split(",").map { |id| Integer(id, exception: false) }.compact.uniq
      .first(RedmineMirror::Source::USERS_PER_REQUEST)
    @users = User.where(type: "User", id: RedmineMirror::Source.project_user_ids(@project, ids))
      .preload(:email_address, :custom_values).order(:id).to_a
    @company_field = RedmineMirror.user_company_field
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @users.size,
      details: { "users" => @users.map { |user| { "id" => user.id, "title" => user.name } } })
    respond_to { |format| format.api }
  end

  # Optional aliases supplied by Localizable for references this project can use. They
  # improve matching only: the destination never imports or updates these translations.
  def localized_names
    names = RedmineMirror::LocalizedNames.source_aliases(@project)
    count = names.values.sum(&:size)
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: count,
      details: { "localized_names" => names.transform_values(&:size) })
    render json: { "localized_names" => names }
  end

  # The project's own categories, with their sharing with subprojects when this Redmine
  # has it (none or descendants), and their default assignee.
  def issue_categories
    @sharing = RedmineMirror::Source.category_sharing?
    @categories = IssueCategory.where(project_id: @project.id).preload(:assigned_to).order(:id).to_a
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @categories.size,
      details: { "issue_categories" => @categories.map { |category| { "id" => category.id, "title" => category[:name] } } })
    respond_to { |format| format.api }
  end

  # The project's own enumerations (Project Enumerations plugin): field, value,
  # status, sharing and position. Those shared by a parent project come with the parent.
  def project_enumerations
    @enumerations = ::ProjectEnumeration.where(project_id: @project.id).preload(:custom_field).order(:id).to_a
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @enumerations.size,
      details: { "project_enumerations" => @enumerations.map { |enumeration| { "id" => enumeration.id, "title" => enumeration.value } } })
    respond_to { |format| format.api }
  end

  def project_enumeration
    RedmineMirror::Source.log(@project, request, User.current, "show", object_count: 1,
      details: { "project_enumerations" => [{ "id" => @enumeration.id, "title" => @enumeration.value }] })
    respond_to { |format| format.api }
  end

  # The project's repositories: SCM, identifier, URL and encodings, and their login and
  # password only when the administrator and the project both allow credentials. The
  # log names the repositories, never their credentials.
  def repositories
    @repositories = @project.repositories.order(:id).to_a
    # Only when asked: a destination asks only to write a repository with them.
    @credentials = params[:credentials] == "1" && RedmineMirror::Source.refusal(@project, "repository_credentials", User.current).nil?
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @repositories.size,
      details: { "repositories" => @repositories.map { |repository| { "id" => repository.id, "title" => repository.identifier.presence || repository.scm_name } },
                 "credentials" => @credentials })
    respond_to { |format| format.api }
  end

  # The links between a repository's changesets and issues, by revision, a page at a time.
  def repository_links
    offset = [params[:offset].to_i, 0].max
    ids = Changeset.where(repository_id: @repository.id).joins(:issues).distinct.order(:id).offset(offset)
      .limit(RedmineMirror::Source::LINKS_PER_PAGE).pluck(:id)
    issues = Changeset.where(id: ids).joins(:issues).pluck(:id, "#{Issue.table_name}.id").group_by(&:first)
    @links = Changeset.where(id: ids).order(:id).pluck(:id, :revision).map { |id, revision| [revision, issues.fetch(id, []).map(&:last).sort] }
    @total = Changeset.where(repository_id: @repository.id).joins(:issues).distinct.count
    @offset = offset
    RedmineMirror::Source.log(@project, request, User.current, "show", object_count: @links.size,
      details: { "repositories" => [{ "id" => @repository.id, "title" => @repository.identifier.presence || @repository.scm_name }], "links" => @links.size })
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

  def find_project_enumeration
    @enumeration = ::ProjectEnumeration.find(params[:id])
    @project = @enumeration.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_repository
    @repository = Repository.find(params[:id])
    @project = @repository.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def check_plugin
    available = case action_name
                when "scrum" then RedmineMirror::Source.scrum_available?
                when "project_enumerations", "project_enumeration" then RedmineMirror::Source.project_enumerations_available?
                else RedmineMirror::Source.tags_available?
                end
    return if available
    response.headers[RedmineMirror::Source::REFUSAL_HEADER] = "unavailable"
    render_404
  end

  def kind
    case action_name
    when "news", "news_item" then "news"
    when "issue_tags" then "issue_tags"
    when "scrum" then "scrum"
    when "queries" then "queries"
    when "users" then "users"
    when "localized_names" then "localized_names"
    when "subprojects" then "subprojects"
    when "issue_categories" then "issue_categories"
    when "project_enumerations", "project_enumeration" then "project_enumerations"
    when "repositories", "repository_links" then "repositories"
    when "download" then RedmineMirror::Source::CONTAINERS.fetch(@attachment.container_type)
    else "documents"
    end
  end

  # An address outside the administrator's list, or a request not authenticated by its API
  # key header, is refused without naming any project. Logged by Rails only: the access log
  # belongs to a project.
  def check_caller
    address = RedmineMirror::Source.caller_address(request)
    if !RedmineMirror::Source.address_allowed?(address)
      reason = "address"
    elsif !RedmineMirror::Source.api_key_request?(request, User.current)
      reason = "api_key"
    else
      return
    end
    logger&.warn("Mirror source refused #{request.path} from #{address}: #{reason}")
    response.headers[RedmineMirror::Source::REFUSAL_HEADER] = reason
    render_403
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
