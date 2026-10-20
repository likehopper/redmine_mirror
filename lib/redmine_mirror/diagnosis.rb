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
      end
    end

    # Errors grouped by cause, the largest first: fixing the first one unblocks the
    # most objects. Each group: {key:, code:, params:, reason:, count:}.
    def groups(events)
      events.select { |event| event["action"] == "error" }.group_by { |event| group_key(event) }.map do |key, rows|
        code, params = cause(rows.first["reason"], rows.first["details"])
        { key: key, code: code, params: params || {}, reason: rows.first["reason"].to_s, count: rows.size }
      end.sort_by { |group| -group[:count] }
    end

    # Errors of one cause share a key: the reason without the object it is about.
    def group_key(event)
      code, params = cause(event["reason"], event["details"])
      case code
      when "missing_mapping" then "missing_mapping:#{params['kind']}:#{params['id']}"
      when "missing_reference" then "missing_reference:#{params['field']}:#{params['id']}"
      else event["reason"].to_s.sub(/ for (\w+) source ID \d+\z/, ' for \\1')
      end
    end
  end
end
