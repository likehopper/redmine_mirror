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

require "ipaddr"

module RedmineMirror
  module Source
    module_function

    # Data a project can share. News have a REST API, but not their comments nor files;
    # issue tags (Redmine Tags plugin by RedmineUP) and Scrum sprints (Scrum plugin) have none.
    # The users API gives logins and emails to administrators only. The categories API
    # lists categories to their managers only, and never says whether they are shared.
    # Project enumerations (plugin) have an API for their managers only. Repositories
    # have no API at all; their credentials are a kind of their own, never allowed by default.
    KINDS = %w[documents news issue_tags scrum queries users issue_custom_fields issue_categories project_enumerations repositories repository_credentials].freeze
    # Kinds an administrator must check explicitly, even before saving a choice: personal
    # data (users' emails, other users' saved queries) and repository access.
    EXPLICIT_KINDS = %w[queries users issue_custom_fields repositories repository_credentials].freeze
    # Redmine project module a kind's data lives in: without it, there is nothing to share.
    KIND_MODULES = { "documents" => "documents", "news" => "news", "issue_tags" => "issue_tracking", "scrum" => "scrum",
      "issue_custom_fields" => "issue_tracking", "issue_categories" => "issue_tracking",
      "repositories" => "repository", "repository_credentials" => "repository" }.freeze

    # Kinds whose project module the project has not enabled.
    def kinds_without_module(project)
      KIND_MODULES.select { |_, name| !project.module_enabled?(name) }.keys
    end

    # Native permission the API account needs for each kind.
    PERMISSIONS = { "documents" => :view_documents, "news" => :view_news, "issue_tags" => :view_issues,
      "scrum" => :view_sprint_board, "queries" => :view_issues, "users" => :view_members, "issue_custom_fields" => :view_issues,
      "issue_categories" => :view_issues, "project_enumerations" => :view_issues,
      "repositories" => :manage_repository, "repository_credentials" => :manage_repository, "changes" => :view_issues }.freeze
    # Changesets linked to issues, per page of a repository's links.
    LINKS_PER_PAGE = 500
    # Users a destination may ask for in one request.
    USERS_PER_REQUEST = 100
    # Email digests a destination may send in one user_matches request.
    DIGESTS_PER_REQUEST = 1_000
    # Saved queries a project shares: issues, time entries and agile boards.
    QUERY_TYPES = %w[IssueQuery TimeEntryQuery AgileQuery].freeze
    # The kind a shared file belongs to, by its container.
    CONTAINERS = { "Document" => "documents", "News" => "news" }.freeze
    # Sent by Mirror clients; the source keeps it only when it has this exact form.
    SESSION = /\A[0-9a-f]{32}\z/
    PURPOSES = %w[references preview synchronization].freeze
    REFUSAL_HEADER = "X-Mirror-Source-Refusal"
    APPLICATION_KEY_HEADER = "X-Mirror-Application-Key"

    def settings
      (Setting.plugin_redmine_mirror rescue {}).to_h
    end

    # Switched on by the administrator and restricted to listed addresses: without any
    # address, Mirror source stays off, so that an API key alone never opens it.
    def enabled?
      switched_on? && allowed_address_entries.any?
    end

    def switched_on?
      settings["source_enabled"].to_s == "1"
    end

    # Switched on but kept off for lack of an allowed address: the administrator is warned.
    def address_missing?
      switched_on? && allowed_address_entries.empty?
    end

    # The change journal behind incremental runs (SourceChanges). On unless the
    # administrator suspends it: settings saved before this option lack the key.
    def changes_enabled?
      settings["source_changes_enabled"].to_s != "0"
    end

    # The addresses an administrator allows to call Mirror source: IPs or networks (CIDR),
    # one per line. None listed, or none valid: no address, so that an empty list or a typo
    # never opens the source.
    def address_allowed?(ip)
      entries = allowed_address_entries
      return false if entries.empty?
      address_in?(ip, entries)
    end

    def allowed_address_entries
      address_entries(settings["source_allowed_addresses"])
    end

    # Reverse proxies in front of Redmine whose X-Forwarded-For is trusted, besides a proxy
    # on this host (loopback). An invalid entry trusts nothing.
    def trusted_proxy_entries
      address_entries(settings["source_trusted_proxies"])
    end

    def address_entries(value)
      value.to_s.split(/[\s,;]+/).reject(&:empty?)
    end

    def address_in?(ip, entries)
      address = IPAddr.new(ip.to_s)
      Array(entries).any? do |entry|
        begin
          IPAddr.new(entry).include?(address)
        rescue IPAddr::Error
          false
        end
      end
    rescue IPAddr::Error
      false
    end

    def client_refusal(project, request, user)
      setting = project.mirror_source_setting
      return "client_address" unless setting&.client_address_allowed?(caller_address(request))
      return "client_user" unless setting.authorized_user_ids.include?(user.id)
      return "client_key" unless setting.client_key_matches?(request.headers[APPLICATION_KEY_HEADER])
    end

    LOOPBACK = %w[127.0.0.0/8 ::1].freeze

    def trusted_proxy?(ip)
      address_in?(ip, LOOPBACK + trusted_proxy_entries)
    end

    # The caller's address: the connection's, unless it comes from a trusted proxy (on this
    # host, or listed): then the address that proxy appended to X-Forwarded-For, and so on
    # back through trusted proxies. A header sent by anyone else is ignored: it could name
    # any address. Rails' remote_ip skips private addresses, so a destination on the same
    # network would read as the proxy itself.
    def caller_address(request)
      forwarded = request.headers["X-Forwarded-For"].to_s.split(",").map(&:strip).reject(&:empty?)
      hops = forwarded + [request.remote_addr.to_s]
      index = hops.size - 1
      index -= 1 while index.positive? && trusted_proxy?(hops[index])
      hops[index]
    end

    # Mirror source answers only requests authenticated by the API key header that Mirror
    # clients send: never a browser session, a login and password, nor a key in the URL
    # (it would end up in logs).
    def api_key_request?(request, user)
      key = request.headers["X-Redmine-API-Key"].to_s
      !key.empty? && user.logged? && User.find_by_api_key(key) == user
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

    # Project enumerations need the Project Enumerations plugin on this Redmine.
    def project_enumerations_available?
      defined?(::ProjectEnumeration) ? true : false
    end

    # Categories shared with subprojects (a patch or plugin adding issue_categories.sharing).
    def category_sharing?
      IssueCategory.column_names.include?("sharing")
    end

    # Data this Redmine can serve: tags and sprints need their plugin.
    def available_kinds
      KINDS.select do |kind|
        case kind
        when "issue_tags" then tags_available?
        when "scrum" then scrum_available?
        when "project_enumerations" then project_enumerations_available?
        else true
        end
      end
    end

    # Data the administrator allows projects to share, among the available data. Until
    # the administrator saves the choice (installations up to 1.0.0-beta.31), all of it.
    def allowed_kinds
      chosen = settings["source_kinds"]
      return available_kinds - EXPLICIT_KINDS if chosen.nil?
      available_kinds & Array(chosen).map(&:to_s)
    end

    # Among the requested IDs, the users who are members of the project or appear in its
    # data that the API account can see: visible issues, notes (private ones only with
    # their permission), time entries, watchers, user fields, news, wiki pages and files.
    # Otherwise an invisible private issue would still reveal its participants' emails.
    # Ruby 2.6 (Redmine 4): no filter_map on the source side.
    def project_user_ids(project, ids, user = User.current)
      ids = ids.uniq
      return [] if ids.empty?
      issues = Issue.visible(user).where(project_id: project.id)
      issue_ids = issues.select(:id)
      found = Member.where(project_id: project.id, user_id: ids).pluck(:user_id)
      found |= issues.where(author_id: ids).pluck(:author_id)
      found |= issues.where(assigned_to_id: ids).pluck(:assigned_to_id)
      journals = Journal.where(journalized_type: "Issue", journalized_id: issue_ids, user_id: ids)
      journals = journals.where(private_notes: false) unless user.allowed_to?(:view_private_notes, project)
      found |= journals.pluck(:user_id)
      found |= TimeEntry.visible(user).where(project_id: project.id, user_id: ids).pluck(:user_id)
      if user.allowed_to?(:view_issue_watchers, project)
        found |= Watcher.where(watchable_type: "Issue", watchable_id: issue_ids, user_id: ids).pluck(:user_id)
      end
      found |= CustomValue.joins(:custom_field).where(custom_fields: { field_format: "user" }, customized_type: "Issue",
        customized_id: issue_ids, value: ids.map(&:to_s)).pluck(:value).map(&:to_i)
      news = News.visible(user).where(project_id: project.id)
      found |= news.where(author_id: ids).pluck(:author_id)
      if user.allowed_to?(:view_wiki_pages, project)
        found |= WikiContent.joins(page: :wiki).where(wikis: { project_id: project.id }, author_id: ids).pluck(:author_id)
      end
      containers = { "Issue" => issue_ids, "Document" => Document.visible(user).where(project_id: project.id).select(:id),
        "News" => news.select(:id) }
      if user.allowed_to?(:view_files, project)
        containers["Project"] = [project.id]
        containers["Version"] = project.versions.select(:id)
      end
      containers.each do |type, scope|
        found |= Attachment.where(container_type: type, container_id: scope, author_id: ids).pluck(:author_id)
      end
      found & ids
    end

    def shared?(project, kind)
      project.module_enabled?(:mirror_source) && project.mirror_source_setting&.shared_modules.to_a.include?(kind)
    end

    # Incremental tombstones keep only identifiers, so a deleted private object can no
    # longer be checked through a visible scope. Offer this optimization only to a
    # dedicated reader whose role can see the full project; other clients use ordinary
    # full reads, where every endpoint applies Redmine's current visibility.
    def full_change_visibility?(project, user)
      change_visibility_gaps(project, user).empty?
    end

    # What an account lacks for the incremental feed of a project: [] when nothing.
    def change_visibility_gaps(project, user)
      return [] if user.admin?
      roles = user.roles_for_project(project)
      gaps = []
      gaps << :issues_visibility unless roles.any? { |role| role.respond_to?(:issues_visibility) && role.issues_visibility == "all" }
      gaps << :time_entries_visibility unless roles.any? { |role| !role.respond_to?(:time_entries_visibility) || role.time_entries_visibility == "all" }
      %i[view_private_notes view_members view_time_entries].each { |permission| gaps << permission unless user.allowed_to?(permission, project) }
      gaps
    end

    # What keeps destinations out of a project, for its settings page: the project locks,
    # what each authorized account lacks, and subprojects whose locks differ.
    def client_status(project)
      setting = project.mirror_source_setting
      accounts = User.where(id: setting&.authorized_user_ids.to_a).order(:id).map do |user|
        { user: user, problems: account_problems(project, user, setting) }
      end
      children = project.descendants.where.not(status: Project::STATUS_ARCHIVED).to_a.select { |child| child.module_enabled?(:mirror_source) }
      { addresses: setting&.client_addresses.to_s.split("\n").reject(&:empty?), key: setting&.client_key? || false, accounts: accounts,
        children_out_of_sync: children.count { |child| !same_clients?(child.mirror_source_setting, setting) } }
    end

    def account_problems(project, user, setting)
      return [[:locked, []]] unless user.active?
      return [[:admin, []]] if user.admin?
      problems = []
      wanted = [:view_issues] + setting.shared_modules.map { |kind| PERMISSIONS[kind] }
      missing = wanted.compact.uniq.reject { |permission| user.allowed_to?(permission, project) }
      problems << [:permissions, missing] if missing.any?
      gaps = changes_enabled? ? change_visibility_gaps(project, user) : []
      problems << [:incremental, gaps] if gaps.any?
      problems
    end

    def same_clients?(child, parent)
      return parent.nil? if child.nil?
      return false if parent.nil?
      MirrorSourceSetting::CLIENT_COLUMNS.all? { |column| child[column].to_s == parent[column].to_s }
    end

    # Why a request is refused, or nil when it is served. The order tells the
    # destination which lock to open: administrator, project module, shared data, account.
    # Data the administrator does not allow is refused as "disabled": the same lock.
    def refusal(project, kind, user)
      # Project structure and optional reference aliases are metadata of data already
      # visible through Redmine's API: no separate sharing choice, only the source locks.
      if %w[subprojects localized_names changes].include?(kind)
        return "disabled" unless enabled?
        return "module" unless project.module_enabled?(:mirror_source)
        if kind == "changes"
          return "permission" unless user.allowed_to?(PERMISSIONS.fetch(kind), project)
          return "incremental_visibility" unless full_change_visibility?(project, user)
        end
        return nil
      end
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
      Digest::SHA256.hexdigest("#{user.id}|#{caller_address(request)}|#{Date.current}")[0, 32]
    end

    def purpose(request)
      value = request.headers["X-Mirror-Purpose"].to_s
      PURPOSES.include?(value) ? value : nil
    end

    def log(project, request, user, action, object_count: 0, bytes: 0, reason: nil, kind: nil)
      key = session_key(request, user)
      # A new session prunes the entries past the retention period.
      unless MirrorSourceAccess.where(session_key: key).exists?
        MirrorSourceAccess.where("created_at < ?", retention_days.days.ago).delete_all
      end
      MirrorSourceAccess.create!(project: project, user_id: user.logged? ? user.id : nil, session_key: key,
        purpose: purpose(request), remote_ip: caller_address(request).to_s[0, 45], action: action, reason: reason,
        object_count: object_count, bytes: bytes, details: JSON.generate("kind" => kind.to_s.presence), created_at: Time.current)
    end
  end
end
