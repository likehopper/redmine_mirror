# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/agile.rb
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
# Convert Scrum plugin sprints and issue data into redmine_agile sprints and agile data.

require "time"

module RedmineMirror
  module Adapters
    # The Scrum plugin has no REST API: the source must run Mirror and share it (Mirror
    # source). The destination needs redmine_agile (PRO, for sprints). Both adapters read
    # the same source response; the remaining effort history has no agile equivalent.
    module Agile
      SOURCE_VERSION = "1.0.0-beta.30"
      PATH = "mirror/source/scrum.json"
      # Scrum status => agile status: a locked sprint is not finished (agile: open 0,
      # active 1, closed 2; only one sprint per project may be active).
      STATUSES = { "open" => 0, "locked" => 0, "closed" => 2 }.freeze
      REFUSALS = {
        "disabled" => "Mirror source is disabled on the source Redmine: its administrator must allow it (Administration → Plugins → Redmine Mirror)",
        "module" => "Enable the Mirror source module on the source project",
        "not_shared" => "Share Scrum sprints in the source project's Settings → Mirror source",
        "permission" => "The source API key needs View sprint board in the source project",
        "unavailable" => "The source Redmine has no Scrum plugin"
      }.freeze

      module_function

      def fetch(client, project_id)
        client.get("projects/#{Integer(project_id)}/#{PATH}").fetch("scrum")
      rescue Error => error
        reason = error.message[/\(Mirror source: ([a-z_]+)\)/, 1]
        raise Error, REFUSALS.fetch(reason) if REFUSALS.key?(reason)
        raise Error, "The source Redmine does not list Scrum sprints: install Redmine Mirror #{SOURCE_VERSION} or later on it" if error.message.include?("HTTP 404")
        raise Error, REFUSALS.fetch("permission") if error.message.include?("HTTP 403") || error.message.include?("HTTP 401")
        raise
      end

      # redmine_agile stores whole story points: a fraction is rounded up (0.5 becomes 1).
      def story_points(value)
        return nil if value.to_s.strip.empty?
        Float(value.to_s.tr(",", ".")).ceil
      rescue ArgumentError
        TextFormat.warning("Story points \"#{value}\" are not a number; left empty")
        nil
      end

      def available?
        defined?(::AgileSprint) && defined?(::AgileData) ? true : false
      end

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end
    end

    # One agile sprint per Scrum sprint; product backlogs become sprints too, under their name.
    class AgileSprints < Base
      def key; "agile_sprints"; end
      def project_module; :agile; end
      def phase; :references; end
      def available?; Agile.available?; end
      def selection_hint; :text_mirror_agile_source_hint; end

      # Names are unique per project in redmine_agile: of the source sprints sharing a name,
      # the first keeps it and the others get their source number, whatever the order of
      # the runs and the local names.
      def records(client, project_id)
        first = {}
        Agile.fetch(client, project_id).fetch("sprints").sort_by { |row| row.fetch("id") }.map do |row|
          name = row.fetch("name").to_s
          unique = first.key?(name) ? "#{name} (#{row.fetch('id')})" : name
          first[name] ||= row.fetch("id")
          row.merge("project" => { "id" => Integer(project_id) }, "unique_name" => unique)
        end
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        raise Error, "Install redmine_agile (PRO) on this Redmine" unless available?
        project = Project.find(project_id)
        raise Error, "Enable the Agile module on the destination project" unless project.module_enabled?(:agile)
        mapping = store.find(key, record.fetch("id"))
        sprint = mapping && find_sprint(project, mapping.fetch("destination_id"))
        name = record.fetch("name")
        if mapping && !sprint
          Policy.local_change!("Local modification detected for sprint \"#{name}\": the sprint was deleted")
          TextFormat.note("recreated")
        elsif sprint && Agile.digest(local_state(sprint)) != mapping.fetch("destination_fingerprint")
          Policy.local_change!("Local modification detected for sprint \"#{name}\"")
          TextFormat.note("local_overwritten")
        end
        attributes = imported_attributes(record, project, sprint)
        changed = sprint.nil? || local_state(sprint) != attributes
        event = { module: key, source_id: record.fetch("id"), destination_id: sprint&.id, action: sprint ? (changed ? "update" : "unchanged") : "create" }
        return event unless apply && changed
        MirrorMapping.transaction do
          sprint = write_sprint(project, sprint, attributes)
          store.save(key, record.fetch("id"), "destination_id" => sprint.id, "source_fingerprint" => Agile.digest(record.except("project", "unique_name")),
            "destination_fingerprint" => Agile.digest(local_state(sprint)))
        end
        event.merge(destination_id: sprint.id)
      end

      def find_sprint(project, id)
        ::AgileSprint.find_by(id: id, project_id: project.id)
      end

      # The status is written after the validations: redmine_agile refuses to close a
      # sprint that holds open issues, which Scrum allowed.
      def write_sprint(project, sprint, attributes)
        sprint ||= ::AgileSprint.new(project: project, status: Agile::STATUSES.fetch("open"))
        sprint.assign_attributes(attributes.except("status"))
        sprint.save!
        sprint.update_columns(status: attributes.fetch("status")) unless sprint.status == attributes.fetch("status")
        sprint
      end

      def local_state(sprint)
        { "name" => sprint.name, "description" => sprint.description.to_s, "start_date" => sprint.start_date&.iso8601,
          "end_date" => sprint.end_date&.iso8601, "status" => sprint.status, "sharing" => sprint.sharing }
      end

      private

      # A local sprint created by hand may hold the name too: then the source number is
      # added as well. Backlogs without dates take their creation date.
      def imported_attributes(record, project, sprint)
        name = record["unique_name"] || record.fetch("name").to_s
        name = "#{record.fetch('name')} (#{record.fetch('id')})" if name_taken?(project, name, sprint)
        created = record["created_on"] ? Time.iso8601(record["created_on"]).to_date : Date.current
        start_date = record["start_date"].presence || record["end_date"].presence || created.iso8601
        { "name" => name, "description" => record["description"].to_s, "start_date" => start_date,
          "end_date" => record["end_date"].presence || start_date,
          "status" => Agile::STATUSES.fetch(record.fetch("status")) { raise Error, "Unknown Scrum sprint status #{record['status']}" },
          "sharing" => record["shared"] ? 1 : 0 }
      end

      def name_taken?(project, name, sprint)
        ::AgileSprint.where(project_id: project.id, name: name).where.not(id: sprint&.id).exists?
      end
    end

    # Sprint, backlog position and story points of imported issues, as agile data.
    class AgileIssues < Base
      def key; "agile_issues"; end
      def project_module; :agile; end
      def phase; :history; end
      def dependencies; %w[issue_tracking agile_sprints]; end
      def available?; Agile.available?; end
      def selection_hint; :text_mirror_agile_source_hint; end

      def records(client, project_id)
        Agile.fetch(client, project_id).fetch("issues").map { |row| row.merge("project" => { "id" => Integer(project_id) }) }
      end

      # Source wins only in mirror mode; otherwise a local change is a conflict.
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        raise Error, "Install redmine_agile (PRO) on this Redmine" unless available?
        local_id = lookup.call("issue_tracking", record.fetch("id"))
        sprint_id = record["sprint_id"] && lookup.call("agile_sprints", record["sprint_id"])
        if record["sprint_id"] && !sprint_id
          raise Error.new("Missing sprint correspondence for source issue ##{record['id']} (sprint ##{record['sprint_id']}); " \
            "synchronize the source project that owns it first", details: { "code" => "missing_reference", "field" => "sprint",
              "id" => record["sprint_id"].to_s, "name" => "" })
        end
        event = { module: key, source_id: record.fetch("id"), destination_id: local_id, action: "update" }
        planned = local_id.to_s.start_with?("planned:") || sprint_id.to_s.start_with?("planned:")
        return event if planned && !apply
        issue = Issue.find_by(id: local_id, project_id: project_id) if local_id
        raise Error, "Missing destination issue correspondence" unless issue
        attributes = { "agile_sprint_id" => sprint_id, "position" => record["position"], "story_points" => Agile.story_points(record["story_points"]) }
        current = read_data(issue)
        previous = store.find(key, record.fetch("id"))
        if previous && Agile.digest(current) != previous.fetch("destination_fingerprint") && current != attributes
          Policy.local_change!("Local modification detected for the agile data of issue ##{issue.id}")
          TextFormat.note("local_overwritten")
        end
        event[:action] = current == attributes ? "unchanged" : "update"
        event[:destination_id] = issue.id
        return event unless apply
        MirrorMapping.transaction do
          write_data(issue, attributes) unless current == attributes
          store.save(key, record.fetch("id"), "destination_id" => issue.id, "source_fingerprint" => Agile.digest(record.except("project")),
            "destination_fingerprint" => Agile.digest(read_data(issue)))
        end
        event
      end

      def read_data(issue)
        data = ::AgileData.find_by(issue_id: issue.id)
        { "agile_sprint_id" => data&.agile_sprint_id, "position" => data&.position, "story_points" => data&.story_points }
      end

      # Agile data only: the issue is not saved, so no journal nor notification.
      def write_data(issue, attributes)
        data = ::AgileData.find_or_initialize_by(issue_id: issue.id)
        data.assign_attributes(attributes)
        data.save!
      end
    end
  end
end
