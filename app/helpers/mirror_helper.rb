# frozen_string_literal: true
# File: redmine_mirror/app/helpers/mirror_helper.rb
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
# Build native and remote object links without exposing configured API credentials.

module MirrorHelper
  def mirror_module_label(key)
    RedmineMirror::REGISTRY.keys.include?(key) ? l("label_mirror_module_#{key}".to_sym) : key
  end

  def mirror_extension(key)
    RedmineMirror::REGISTRY[key] || RedmineMirror::REGISTRY.mapping_table(key)
  end

  def mirror_object_link(module_key, id, source_url: nil, local_issue_id: nil)
    return "—" if id.blank?
    id = Integer(id)
    local_id = source_url && @project ? MirrorMapping.find_by(project_id: @project.id, module_key: module_key, source_id: id)&.destination_id : id
    if %w[issue_journals issue_relation_notes].include?(module_key)
      local_issue_id ||= Journal.find_by(id: local_id)&.journalized_id if local_id
    elsif module_key == "issue_relations"
      local_issue_id ||= IssueRelation.find_by(id: local_id)&.issue_from_id if local_id
    end
    remote_issue_id = source_url && local_issue_id && @project ? MirrorMapping.find_by(project_id: @project.id, module_key: "issue_tracking", destination_id: local_issue_id)&.source_id : nil
    path = case module_key
           when "user", "users" then user_path(id)
           when "custom_field" then "/custom_fields/#{id}/edit"
           when "tracker" then "/trackers/#{id}/edit"
           when "status" then "/issue_statuses/#{id}/edit"
           when "priority", "activity" then "/enumerations/#{id}/edit"
           when "issue_tracking", "issue_hierarchy", "issue_watchers", "issue_custom_fields" then issue_path(id)
           when "time_tracking" then edit_time_entry_path(id)
           when "issue_attachments" then "/attachments/#{id}"
           when "project_versions" then version_path(id)
           when "issue_categories" then "/projects/#{@project.identifier}/issue_categories/#{id}/edit"
           when "issue_journals", "issue_relation_notes"
             return id.to_s unless local_issue_id
             "#{issue_path(local_issue_id)}#change-#{id}"
           when "issue_relations"
             return id.to_s unless local_issue_id
             "#{issue_path(local_issue_id)}#relations"
           else
             # External adapters and their reference tables provide their own routes.
             extension = mirror_extension(module_key)
             extension&.local_path(id, @project) or return id.to_s
           end
    if source_url
      base = URI.parse(source_url)
      return id.to_s unless %w[http https].include?(base.scheme) && base.host && !base.userinfo
      # The isolated demo API hostname is only resolvable inside Docker.
      if ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && %w[source gateway].include?(base.host)
        base = URI.parse("http://localhost:3101")
      end
      remote_path = case module_key
                    when "user", "users" then "users/#{id}"
                    when "custom_field" then "custom_fields/#{id}/edit"
                    when "tracker" then "trackers/#{id}/edit"
                    when "status" then "issue_statuses/#{id}/edit"
                    when "priority", "activity" then "enumerations/#{id}/edit"
                    when "issue_tracking", "issue_hierarchy", "issue_watchers", "issue_custom_fields" then "issues/#{id}"
                    when "issue_attachments" then "attachments/#{id}"
                    when "project_versions" then "versions/#{id}"
                    when "issue_categories"
                      setting = @setting || @project.mirror_project_setting
                      "projects/#{setting.source_project_id}/issue_categories/#{id}/edit"
                    when "issue_journals", "issue_relation_notes", "issue_relations"
                      return id.to_s unless remote_issue_id
                      anchor = module_key == "issue_relations" ? "relations" : "change-#{id}"
                      "issues/#{remote_issue_id}##{anchor}"
                    when "time_tracking" then "time_entries/#{id}/edit"
                    else mirror_extension(module_key)&.remote_path(id, @setting || @project.mirror_project_setting) or return id.to_s
                    end
      path = "#{base.to_s.sub(%r{/+\z}, '')}/#{remote_path}"
    end
    link_to id, path
  rescue ArgumentError, URI::InvalidURIError
    id.to_s
  end
end
