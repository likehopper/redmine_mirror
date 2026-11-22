# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/diagnosis.rb
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
# Recognize the cause of a run error, so that the log explains it and links to its fix
# (MirrorHelper#mirror_guidance). New errors carry details; older logs only have text.

module RedmineMirror
  module Diagnosis
    module_function

    # [code, params] of a known cause, else nil.
    def cause(reason, details = nil)
      return [details["code"], details] if details.is_a?(Hash) && details["code"]
      text = reason.to_s
      case text
      when /\AMissing (\w+) mapping for source ID (\d+)/
        ["missing_mapping", { "kind" => Regexp.last_match(1), "id" => Regexp.last_match(2) }]
      when /\AMissing (category|fixed_version) correspondence for source issue #\d+ \(\w+ #(\d+) "(.*?)"\)/
        ["missing_reference", { "field" => Regexp.last_match(1), "id" => Regexp.last_match(2), "name" => Regexp.last_match(3) }]
      when /\ACustom field "(.+?)" is not enabled for destination tracker/
        ["field_not_on_tracker", { "name" => Regexp.last_match(1) }]
      when /mapped to source field #(\d+) is not enabled in this project/
        ["field_not_in_project", { "id" => Regexp.last_match(1) }]
      when /value mapping for custom field|incompatible formats|Invalid value for custom field|custom_field mapping/
        ["field_values", {}]
      when /\ALocal modification detected/
        ["conflict", {}]
      when /maximum attachment size/
        ["attachment_size", {}]
      when /\AEnable the (\w+) module on the destination project/
        ["project_module", { "module" => Regexp.last_match(1).downcase }]
      when /HTTP 403 for GET (\S+)/
        ["source_permission", { "path" => Regexp.last_match(1) }]
      when /\ADeletion awaits confirmation/
        ["deletions", {}]
      when /Assignee is invalid/
        ["assignee_not_assignable", {}]
      when /\AMissing (destination|owning) issue correspondence|\AIssue has no synchronized destination/
        ["issue_not_imported", {}]
      when /\AParent wiki page "(.*)" is not imported/
        ["wiki_parent_missing", { "title" => Regexp.last_match(1) }]
      when %r{HTTP 404 for GET \S*attachments/\S*download}
        ["source_file_missing", {}]
      when /\ARedmine cannot read the repository at/
        ["repository_unreadable", {}]
      when /\AMapped watcher cannot view destination issue/
        ["watcher_no_access", {}]
      end
    end

    # Objects that failed only because an object they depend on failed: they pass once
    # that object's own cause is fixed.
    CONSEQUENCES = %w[issue_not_imported wiki_parent_missing].freeze
    # One group for every object, whatever the path or the page named in the reason.
    SHARED_CAUSES = %w[issue_not_imported wiki_parent_missing source_file_missing repository_unreadable watcher_no_access].freeze

    # Errors grouped by cause, the largest first: fixing the first one unblocks the
    # most objects. Each group: {key:, code:, params:, reason:, count:, consequence:, modules:}.
    def groups(events)
      grouped = {}
      events.each do |event|
        next unless event["action"] == "error"
        key = group_key(event)
        group = grouped[key] ||= begin
          code, params = cause(event["reason"], event["details"])
          { key: key, code: code, params: params || {}, reason: generic_reason(event["reason"]), count: 0,
            consequence: CONSEQUENCES.include?(code), modules: {} }
        end
        group[:count] += 1
        module_key = event["module"]
        group[:modules][module_key] = group[:modules].fetch(module_key, 0) + 1
      end
      grouped.values.sort_by { |group| -group[:count] }
    end

    # Errors of one cause share a key: the reason without the object it is about.
    def group_key(event)
      code, params = cause(event["reason"], event["details"])
      case code
      when "missing_mapping" then "missing_mapping:#{params['kind']}:#{params['id']}"
      when "missing_reference" then "missing_reference:#{params['field']}:#{params['id']}"
      when "assignee_not_assignable" then ["assignee_not_assignable", params["id"]].compact.join(":")
      when *SHARED_CAUSES then code
      else generic_reason(event["reason"]).sub(/ for (\w+) source ID \d+\z/, ' for \\1')
      end
    end

    # A refused API call names the object in its path (attachments/download/328): one
    # cause for every object, so the path IDs are replaced.
    def generic_reason(reason)
      reason.to_s.sub(/(HTTP \d+ for [A-Z]+ )(\S+)/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).gsub(%r{/\d+(?=/|\z|\.)}, '/…')}" }
    end
  end
end
