# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/source.rb
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
# Mirror source: the data this Redmine exposes to Mirror destinations, which Redmine's
# REST API does not cover. Three locks, all closed by default: the administrator's
# global switch, the project's Mirror source module and the data the project shares.

module RedmineMirror
  module Source
    module_function

    # Data a project can share. News have a REST API, but not their comments nor files;
    # issue tags (Redmine Tags plugin by RedmineUP) and Scrum sprints (Scrum plugin) have none.
    # The users API gives logins and emails to administrators only.
    KINDS = %w[documents news issue_tags scrum queries users].freeze
    # Native permission the API account needs for each kind.
    PERMISSIONS = { "documents" => :view_documents, "news" => :view_news, "issue_tags" => :view_issues,
      "scrum" => :view_sprint_board, "queries" => :view_issues, "users" => :view_issues }.freeze
    # Users a destination may ask for in one request.
    USERS_PER_REQUEST = 100
    # Saved queries a project shares: issues, time entries and agile boards.
    QUERY_TYPES = %w[IssueQuery TimeEntryQuery AgileQuery].freeze
    # The kind a shared file belongs to, by its container.
    CONTAINERS = { "Document" => "documents", "News" => "news" }.freeze
    # Sent by Mirror clients; the source keeps it only when it has this exact form.
    SESSION = /\A[0-9a-f]{32}\z/
    PURPOSES = %w[references preview synchronization].freeze
    REFUSAL_HEADER = "X-Mirror-Source-Refusal"

    def settings
      (Setting.plugin_redmine_mirror rescue {}).to_h
    end

    def enabled?
      settings["source_enabled"].to_s == "1"
    end

    # Access log retention, in days (plugin settings).
    def retention_days
      days = settings["source_log_days"].to_i
      days.positive? ? days : 180
    end

    # Issue tags need the Redmine Tags plugin on this Redmine.
    def tags_available?
      Issue.method_defined?(:tag_list)
    end

    # Plain JSON values of a saved query option (Rails parameters, symbols).
    def plain(value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = plain(item) }
      when Array then value.map { |item| plain(item) }
      when Symbol then value.to_s
      else value
      end
    end

    # Sprints need the Scrum plugin on this Redmine.
    def scrum_available?
      defined?(::Sprint) && Issue.column_names.include?("sprint_id") ? true : false
    end

    # Data this Redmine can serve: tags and sprints need their plugin.
    def available_kinds
      KINDS.select do |kind|
        case kind
        when "issue_tags" then tags_available?
        when "scrum" then scrum_available?
        else true
        end
      end
    end

    # Data the administrator allows projects to share, among the available data. Until
    # the administrator saves the choice (installations up to 1.0.0-beta.31), all of it.
    def allowed_kinds
      chosen = settings["source_kinds"]
      return available_kinds if chosen.nil?
      available_kinds & Array(chosen).map(&:to_s)
    end

    # Among the requested IDs, the users who are members of the project or appear in its
    # data: issues, notes, time entries, watchers, user fields, news, wiki pages and files.
    # Ruby 2.6 (Redmine 4): no filter_map on the source side.
    def project_user_ids(project, ids)
      ids = ids.uniq
      return [] if ids.empty?
      issues = Issue.where(project_id: project.id).select(:id)
      found = Member.where(project_id: project.id, user_id: ids).pluck(:user_id)
      found |= Issue.where(project_id: project.id, author_id: ids).pluck(:author_id)
      found |= Issue.where(project_id: project.id, assigned_to_id: ids).pluck(:assigned_to_id)
      found |= Journal.where(journalized_type: "Issue", journalized_id: issues, user_id: ids).pluck(:user_id)
      found |= TimeEntry.where(project_id: project.id, user_id: ids).pluck(:user_id)
      found |= Watcher.where(watchable_type: "Issue", watchable_id: issues, user_id: ids).pluck(:user_id)
      found |= CustomValue.joins(:custom_field).where(custom_fields: { field_format: "user" }, customized_type: "Issue",
        customized_id: issues, value: ids.map(&:to_s)).pluck(:value).map(&:to_i)
      found |= News.where(project_id: project.id, author_id: ids).pluck(:author_id)
      found |= WikiContent.joins(page: :wiki).where(wikis: { project_id: project.id }, author_id: ids).pluck(:author_id)
      containers = { "Issue" => issues, "Project" => [project.id], "Version" => project.versions.select(:id),
        "Document" => Document.where(project_id: project.id).select(:id), "News" => News.where(project_id: project.id).select(:id) }
      containers.each do |type, scope|
        found |= Attachment.where(container_type: type, container_id: scope, author_id: ids).pluck(:author_id)
      end
      found & ids
    end

    def shared?(project, kind)
      project.module_enabled?(:mirror_source) && project.mirror_source_setting&.shared_modules.to_a.include?(kind)
    end

    # Why a request is refused, or nil when it is served. The order tells the
    # destination which lock to open: administrator, project module, shared data, account.
    # Data the administrator does not allow is refused as "disabled": the same lock.
    def refusal(project, kind, user)
      return "disabled" unless enabled? && allowed_kinds.include?(kind)
      return "module" unless project.module_enabled?(:mirror_source)
      return "not_shared" unless shared?(project, kind)
      "permission" unless user.allowed_to?(PERMISSIONS.fetch(kind), project)
    end

    # Requests of one destination run share its session; others are grouped per
    # account, address and day.
    def session_key(request, user)
      value = request.headers["X-Mirror-Session"].to_s
      return value if value.match?(SESSION)
      Digest::SHA256.hexdigest("#{user.id}|#{request.remote_ip}|#{Date.current}")[0, 32]
    end

    def purpose(request)
      value = request.headers["X-Mirror-Purpose"].to_s
      PURPOSES.include?(value) ? value : nil
    end

    def log(project, request, user, action, object_count: 0, bytes: 0, reason: nil, details: {})
      key = session_key(request, user)
      # A new session prunes the entries past the retention period.
      unless MirrorSourceAccess.where(session_key: key).exists?
        MirrorSourceAccess.where("created_at < ?", retention_days.days.ago).delete_all
      end
      MirrorSourceAccess.create!(project: project, user_id: user.logged? ? user.id : nil, session_key: key,
        purpose: purpose(request), remote_ip: request.remote_ip.to_s[0, 45], action: action, reason: reason,
        object_count: object_count, bytes: bytes, details: JSON.generate(details), created_at: Time.current)
    end
  end
end
