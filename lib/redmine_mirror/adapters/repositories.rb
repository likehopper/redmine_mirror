# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/repositories.rb
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
# Recreate the project's repositories and their changeset-issue links (Mirror source).

module RedmineMirror
  module Adapters
    # Redmine has no repositories API: the source must run Mirror and share Repositories
    # (and, separately, their credentials). The content is not copied: a Git repository is
    # a path on the server, copied there beforehand (path rewrites map the old prefix to
    # the new one); a Subversion URL is read where it is. Redmine then reads the revisions,
    # and the links to issues are set from the source's, not from commit messages, whose
    # issue numbers are those of the source.
    class Repositories < Base
      SOURCE_VERSION = "1.0.0-beta.36"
      OPTIONS = %w[path_rewrites credentials fetch_changesets].freeze

      def key; "repositories"; end
      def phase; :history; end
      def dependencies; ["issue_tracking"]; end
      def project_module; :repository; end
      def selection_hint; :text_mirror_repositories_source_hint; end
      def record_label; :label_mirror_statistic_repositories; end
      def catalog_statistics(record); { "changesets" => record["changesets_count"].to_i }; end

      REFUSALS = {
        "disabled" => "Mirror source is disabled on the source Redmine: its administrator must allow it, and this data (Administration → Plugins → Redmine Mirror)",
        "module" => "Enable the Mirror source module on the source project",
        "not_shared" => "Share Repositories in the source project's Settings → Mirror source",
        "permission" => "The source API key needs Manage repository in the source project"
      }.freeze

      def records(client, project_id)
        client.get("projects/#{Integer(project_id)}/mirror/source/repositories.json").fetch("repositories")
          .map { |row| { "project" => { "id" => Integer(project_id) } }.merge(row) }.sort_by { |row| row.fetch("id") }
      rescue Error => error
        refused(error)
      end

      # The repository's login and password, when the source shares them; nil otherwise.
      def credentials(source, record)
        rows = source.get("projects/#{Integer(record.fetch('project').fetch('id'))}/mirror/source/repositories.json", "credentials" => "1").fetch("repositories")
        rows.find { |row| row["id"] == record.fetch("id") && row.key?("login") }
      rescue Error => error
        refused(error)
      end

      def refused(error)
        reason = error.message[/\(Mirror source: ([a-z_]+)\)/, 1]
        raise Error, REFUSALS.fetch(reason) if REFUSALS.key?(reason)
        raise Error, "The source Redmine does not list repositories: install Redmine Mirror #{SOURCE_VERSION} or later on it" if error.message.include?("HTTP 404")
        raise Error, REFUSALS.fetch("permission") if error.message.include?("HTTP 403") || error.message.include?("HTTP 401")
        raise
      end

      # path_rewrites: one "old prefix => new prefix" per line; credentials: "1" to keep
      # the login and password the source shares; fetch_changesets: "0" to leave reading
      # the revisions to Redmine's own fetch.
      def configuration_options(input, _project)
        raise Error, "Unsupported repository options" unless (input.keys - OPTIONS).empty?
        rewrites = input["path_rewrites"].to_s.lines.map(&:strip).reject(&:empty?)
        rewrites.each { |line| raise Error, "Invalid path rewrite \"#{line}\": write old prefix => new prefix" unless line.split("=>").size == 2 }
        { "path_rewrites" => rewrites.join("\n"), "credentials" => input["credentials"] == "1" ? "1" : "0",
          "fetch_changesets" => input["fetch_changesets"] == "0" ? "0" : "1" }
      end

      def rewrite(path, options)
        return path if path.to_s.empty?
        options.fetch("path_rewrites", "").to_s.lines.each do |line|
          from, to = line.split("=>", 2).map(&:strip)
          next if from.to_s.empty?
          return to.to_s + path.delete_prefix(from) if path.start_with?(from)
        end
        path
      end

      def attributes(record, options)
        result = { "identifier" => record["identifier"].to_s, "is_default" => !!record["is_default"],
          "url" => rewrite(record.fetch("url").to_s, options), "root_url" => rewrite(record["root_url"].to_s, options),
          "path_encoding" => record["path_encoding"].presence, "log_encoding" => record["log_encoding"].presence }
        result["root_url"] = result["url"] if result["root_url"].empty?
        result
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        options = project.mirror_project_setting&.module_options&.fetch(key, {}) || {}
        scm = record.fetch("scm").to_s
        raise Error, "The #{scm} SCM is not enabled on this Redmine (Administration → Settings → Repositories)" unless Setting.enabled_scm.include?(scm)
        wanted = attributes(record, options)
        row = store.find(key, record.fetch("id"))
        repository = row && Repository.find_by(project_id: project.id, id: row.fetch("destination_id"))
        if row && !repository
          Policy.local_change!("Local modification detected for repositories source ID #{record.fetch('id')}: the destination repository was deleted")
          row = nil
        end
        repository ||= Repository.factory(scm)
        raise Error, "Unknown SCM #{scm}" unless repository
        repository.project = project
        current = repository.attributes.slice(*wanted.keys).merge("is_default" => !!repository.is_default)
        repository.assign_attributes(wanted)
        # Asked for only now, and only when this project keeps them: reading the references
        # or a project that does not keep them never receives them.
        if options["credentials"] == "1" && (shared = credentials(source, record))
          repository.login = shared["login"].presence
          repository.password = shared["password"].presence
        end
        if record["scm"] == "Git" && !record["report_last_commit"].nil?
          repository.merge_extra_info("extra_report_last_commit" => record["report_last_commit"] ? "1" : "0")
        end
        action = row ? (current == wanted && !repository.changed? ? "unchanged" : "update") : "create"
        raise Error, "Destination rejected the repository: #{repository.errors.full_messages.join(', ')}" unless repository.valid?
        event = { module: key, source_id: record.fetch("id"), destination_id: repository.id, action: action }
        return event unless apply
        repository.save!
        store.save(key, record.fetch("id"), "destination_id" => repository.id, "source_fingerprint" => digest(wanted), "destination_fingerprint" => digest(wanted))
        event[:destination_id] = repository.id
        fetch(repository, record) unless options["fetch_changesets"] == "0"
        relink(source, record, repository, lookup, store)
        event
      end

      # Redmine logs a repository it cannot read without failing: a source with revisions
      # and none read here means the content is not where the URL says.
      def fetch(repository, record)
        repository.fetch_changesets
        if record["changesets_count"].to_i.positive? && !Changeset.where(repository_id: repository.id).exists?
          raise Error, "Redmine cannot read the repository at #{repository.url}: copy it there first, or rewrite its path"
        end
      rescue Error
        raise
      rescue StandardError => error
        raise Error, "Redmine cannot read the repository at #{repository.url}: copy it there first, or rewrite its path (#{error.class.name})"
      end

      # The source links by revision, translated into this Redmine's issues. Links Redmine
      # made from commit messages (source issue numbers) are replaced on every changeset.
      def relink(client, record, repository, lookup, store)
        desired = {}
        offset = 0
        loop do
          page = client.get("mirror/source/repositories/#{Integer(record.fetch('id'))}/links.json", "offset" => offset).fetch("repository_links")
          links = page.fetch("links", [])
          links.each do |link|
            ids = Array(link["issue_ids"]).filter_map do |source_issue|
              local = lookup.call("issue_tracking", Integer(source_issue))
              local ||= store.resolve_issue(Integer(source_issue)) if store.respond_to?(:resolve_issue)
              local unless local.nil? || local.to_s.start_with?("planned:")
            end
            desired[link.fetch("revision").to_s] = ids
          end
          offset += links.size
          break if links.empty? || offset >= page.fetch("total_count").to_i
        end
        missing = 0
        changesets = Changeset.where(repository_id: repository.id)
        (changesets.where(revision: desired.keys).to_a | changesets.joins(:issues).distinct.to_a).each do |changeset|
          ids = desired.fetch(changeset.revision.to_s, [])
          next if changeset.issue_ids.sort == ids.sort
          changeset.issue_ids = ids
        end
        missing = (desired.keys - changesets.where(revision: desired.keys).pluck(:revision).map(&:to_s)).size
        TextFormat.warning("#{missing} linked revision(s) not read yet in this repository; links are set once Redmine reads them") if missing.positive?
      rescue Error => error
        refused(error)
      end

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      def local_path(id, project)
        repository = Repository.find_by(id: id, project_id: project.id)
        repository && "/projects/#{project.identifier}/repository/#{repository.identifier_param}"
      end
    end
  end
end
