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
  accept_api_auth :documents, :document, :news, :news_item, :issue_tags, :scrum, :queries, :users, :user_matches, :custom_fields, :issue_categories,
    :project_enumerations, :project_enumeration, :repositories, :repository_links, :download, :localized_names, :subprojects, :changes
  # Once Redmine knows the user, before anything else, the project lookup included: the
  # caller's address and API key.
  before_action :check_caller
  before_action :find_project_by_project_id, only: %i[documents news issue_tags scrum queries users user_matches custom_fields issue_categories project_enumerations repositories localized_names subprojects changes]
  before_action :find_document, only: :document
  before_action :find_news, only: :news_item
  before_action :find_attachment, only: :download
  # A missing plugin first: its permissions do not exist either.
  before_action :check_plugin, only: %i[issue_tags scrum project_enumerations project_enumeration]
  before_action :find_project_enumeration, only: :project_enumeration
  before_action :find_repository, only: :repository_links
  before_action :check_access
  before_action :require_change_journal, only: %i[changes]

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

  # Destinations up to 1.0.0-beta.50 identify themselves (+consumer+) and expect the
  # source to keep their acknowledgements: they get the answer of a source without the
  # journal, and keep synchronizing in their compatible mode until they are upgraded.
  def changes
    return render_404 if params.key?(:consumer)
    after = params[:after].presence && Integer(params[:after])
    raise ArgumentError if after&.negative?
    result = RedmineMirror::SourceChanges.page(@project, after: after)
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: result.fetch(:changes).size,
      details: { "changes" => result.fetch(:changes).size, "cursor" => result.fetch(:cursor) })
    render json: result
  rescue ArgumentError, TypeError
    render json: { error: "Invalid change cursor" }, status: :unprocessable_entity
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
    issues = Issue.visible.where(project_id: @project.id)
    field_id = (Scrum::Setting.story_points_custom_field_id if defined?(Scrum::Setting)).presence
    points = field_id ? CustomValue.where(custom_field_id: field_id, customized_type: "Issue", customized_id: issues.select(:id))
      .where.not(value: [nil, ""]).pluck(:customized_id, :value).to_h : {}
    # Ruby 2.6 (Redmine 4): no filter_map on the source side.
    @scrum_issues = issues.order(:id).pluck(:id, :sprint_id, :position).map do |id, sprint_id, position|
      [id, sprint_id, position, points[id]] if sprint_id || position || points[id]
    end.compact
    # A project issue may use a shared sprint owned by another project. It is part of
    # this explicit sharing because the API account can see the issue that references it.
    used_sprint_ids = @scrum_issues.map { |_, sprint_id, _, _| sprint_id }.compact.uniq
    @sprints = ::Sprint.where(project_id: @project.id).or(::Sprint.where(id: used_sprint_ids)).order(:id).to_a
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @sprints.size + @scrum_issues.size,
      details: { "scrum" => { "sprints" => @sprints.size, "issues" => @scrum_issues.size } })
    respond_to { |format| format.api }
  end

  # The project's saved queries of issues, time entries and agile boards, private ones
  # included: sharing them is the project's explicit choice, and every list is logged.
  def queries
    types = RedmineMirror::Source::QUERY_TYPES.select { |type| Object.const_defined?(type) }
    # Never other users' private queries, nor the account's own: public ones, and those
    # limited to roles, as far as the account can see them.
    @queries = Query.where(project_id: @project.id, type: types).where.not(visibility: Query::VISIBILITY_PRIVATE)
      .preload(:user, :roles).order(:id).to_a.select { |query| query.visible?(User.current) }
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @queries.size,
      details: { "queries" => @queries.map { |query| { "id" => query.id, "title" => "#{query.name} (#{query.type})" } } })
    respond_to { |format| format.api }
  end

  # Login, names, email and company of the requested users (?ids=1,2) who are members of
  # the project or appear in its data; the others are left out without a word. Redmine's
  # users API gives logins and emails to administrators only. An email its owner hides
  # is left out too (user_matches).
  def users
    @users = User.where(type: "User", id: RedmineMirror::Source.project_user_ids(@project, requested_user_ids, User.current))
      .preload(:email_address, :custom_values, :preference).order(:id).to_a
    @company_field = RedmineMirror.user_company_field
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @users.size,
      details: { "users" => @users.map { |user| { "id" => user.id, "title" => user.name } } })
    respond_to { |format| format.api }
  end

  # Which of the requested users (ids, those users() lists) own one of the given email
  # digests (digests: SHA-256 of a lowercased address). A destination sends the digests of
  # its own users' addresses to recognize the accounts whose email is hidden: it learns
  # only addresses it already knows, and never sends them in clear.
  def user_matches
    digests = Array(params[:digests]).map(&:to_s).select { |digest| digest.match?(/\A[0-9a-f]{64}\z/) }.uniq
    return render(json: { error: "Too many digests" }, status: :unprocessable_entity) if digests.size > RedmineMirror::Source::DIGESTS_PER_REQUEST
    wanted = digests.to_set
    users = User.where(type: "User", id: RedmineMirror::Source.project_user_ids(@project, requested_user_ids, User.current))
      .preload(:email_addresses).order(:id).to_a
    matches = users.each_with_object([]) do |user, result|
      digest = user.email_addresses.map { |email| Digest::SHA256.hexdigest(email.address.to_s.downcase) }.find { |value| wanted.include?(value) }
      result << { "id" => user.id, "digest" => digest } if digest
    end
    RedmineMirror::Source.log(@project, request, User.current, "match", object_count: matches.size,
      details: { "users" => users.size, "digests" => digests.size })
    render json: { matches: matches }
  end

  # Definitions of the issue fields this project can use and this account may see.
  # Values remain in Redmine's ordinary issue API; Mirror source only removes the need
  # for an administrator API key to understand their format and allowed choices.
  def custom_fields
    @custom_fields = @project.all_issue_custom_fields.select { |field| field.visible_by?(@project, User.current) }
      .sort_by { |field| [field.position || 0, field.id] }
    RedmineMirror::Source.log(@project, request, User.current, "list", object_count: @custom_fields.size,
      details: { "custom_fields" => @custom_fields.map { |field| { "id" => field.id, "title" => field.name } } })
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
    when "users", "user_matches" then "users"
    when "custom_fields" then "issue_custom_fields"
    when "localized_names" then "localized_names"
    when "changes" then "changes"
    when "subprojects" then "subprojects"
    when "issue_categories" then "issue_categories"
    when "project_enumerations", "project_enumeration" then "project_enumerations"
    when "repositories", "repository_links" then "repositories"
    when "download" then RedmineMirror::Source::CONTAINERS.fetch(@attachment.container_type)
    else "documents"
    end
  end

  # A source switched off, an address outside the administrator's list, or a request not
  # authenticated by its API key header, is refused without naming any project. Logged by
  # Rails only: the access log belongs to a project.
  def check_caller
    address = RedmineMirror::Source.caller_address(request)
    # Switched off, or kept off without any allowed address: refused before anything else.
    if !RedmineMirror::Source.enabled?
      reason = "disabled"
    elsif !RedmineMirror::Source.address_allowed?(address)
      reason = "address"
    elsif !RedmineMirror::Source.api_key_request?(request, User.current)
      reason = "api_key"
    elsif User.current.admin?
      # An administrator bypasses every permission: private issues and notes, all projects.
      # Destinations use a dedicated account given what it may see in the shared projects.
      reason = "admin_account"
    else
      return
    end
    logger&.warn("Mirror source refused #{request.path} from #{address}: #{reason}")
    response.headers[RedmineMirror::Source::REFUSAL_HEADER] = reason
    render_403
  end

  # A suspended journal answers like a source without it: destinations fall back to their
  # compatible mode (ChangeSet.read), and resuming it asks them for a complete pass.
  def require_change_journal
    render_404 unless RedmineMirror::Source.changes_enabled?
  end

  def requested_user_ids
    params[:ids].to_s.split(",").map { |id| Integer(id, exception: false) }.compact.uniq
      .first(RedmineMirror::Source::USERS_PER_REQUEST)
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
