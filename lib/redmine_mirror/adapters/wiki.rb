# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/wiki.rb
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
# Import wiki pages with their versions, parents and attachments through local models.

require "erb"
require "time"

module RedmineMirror
  module Adapters
    # The REST API identifies a wiki page by its title only: the correspondence key is
    # derived from it, and a page renamed on the source is imported as a new page.
    # Local versions keep the source numbers, authors, comments and dates.
    class Wiki < Base
      def key; "wiki"; end
      def phase; :history; end
      def dependencies; ["users"]; end
      def text_samples(record); [record["text"]]; end

      def referenced_users(record)
        ([record["author"]] + record.fetch("attachments", []).map { |attachment| attachment["author"] }).compact
      end

      # Stable positive key below 2**60, case-insensitive like Redmine titles.
      def self.source_id(title)
        Integer(Digest::SHA256.hexdigest(title.to_s.downcase)[0, 15], 16)
      end

      def page_path(project_id, title)
        "projects/#{Integer(project_id)}/wiki/#{ERB::Util.url_encode(title)}"
      end

      # Parents come before their children, so a child finds its parent's correspondence.
      def records(client, project_id)
        index = begin
          client.get("projects/#{Integer(project_id)}/wiki/index.json").fetch("wiki_pages")
        rescue Error => error
          raise unless error.message.match?(/HTTP 40[34]/)
          raise Error, "The source project has no wiki, or the source API key cannot view it"
        end
        parents = index.to_h { |page| [page.fetch("title"), page.dig("parent", "title")] }
        depth = lambda do |title, seen|
          parent = parents[title]
          parent && !seen.include?(parent) ? 1 + depth.call(parent, seen + [title]) : 0
        end
        Enumerator.new do |output|
          index.sort_by { |page| [depth.call(page.fetch("title"), []), page.fetch("title")] }.each do |page|
            detail = client.get("#{page_path(project_id, page.fetch('title'))}.json", "include" => "attachments").fetch("wiki_page")
            output << detail.merge("id" => self.class.source_id(detail.fetch("title")), "project" => { "id" => Integer(project_id) })
          end
        end
      end

      # Authors of earlier versions, so that the Users tab lists every one of them.
      def catalog_references(client, project_id)
        users = records(client, project_id).flat_map do |record|
          versions(client, project_id, record, 1).filter_map { |version| version["author"] }
        end
        { "user" => users.uniq { |user| user.fetch("id") } }
      end

      # Source versions after +after+, the current one included. Deleted versions are gaps.
      def versions(client, project_id, record, after)
        current = Integer(record.fetch("version"))
        ((after + 1)...current).filter_map do |number|
          client.get("#{page_path(project_id, record.fetch('title'))}/#{number}.json").fetch("wiki_page")
        rescue Error => error
          raise Error, "Wiki history needs the source permission View wiki history" if error.message.include?("HTTP 403")
          raise unless error.message.include?("HTTP 404")
          nil
        end + (current > after ? [record] : [])
      end

      def local_path(id, project)
        page = WikiPage.find_by(id: id)
        page && "/projects/#{project.identifier}/wiki/#{ERB::Util.url_encode(page.title)}"
      end

      # The local page has the source title, which the source URL needs.
      def remote_path(id, setting)
        mapping = MirrorMapping.find_by(project_id: setting.project_id, module_key: key, source_id: id)
        page = mapping && WikiPage.find_by(id: mapping.destination_id)
        page && "projects/#{setting.source_project_identifier.presence || setting.source_project_id}/wiki/#{ERB::Util.url_encode(page.title)}"
      end

      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        project = Project.find(project_id)
        wiki = project.wiki
        raise Error, "Enable the Wiki module on the destination project" unless project.module_enabled?(:wiki) && wiki
        title = record.fetch("title")
        mapping = store.find(key, record.fetch("id"))
        page = mapping && wiki.pages.find_by(id: mapping.fetch("destination_id"))
        reset = false
        if mapping && (!page || digest(local_state(page)) != mapping.fetch("destination_fingerprint"))
          Policy.local_change!("Local modification detected for wiki page \"#{title}\"#{page ? '' : ': the page was deleted'}")
          # Mirror mode: the content is imported again, every version. The page keeps its
          # ID, so its subpages and files stay attached.
          TextFormat.note(page ? "local_overwritten" : "recreated")
          reset = !page.nil?
        elsif !mapping && wiki.find_page(title, with_redirect: false)
          raise Error, "Existing local wiki page \"#{title}\" requires manual resolution"
        end
        parent_title = record.dig("parent", "title")
        parent_id = parent_title && lookup.call(key, self.class.source_id(parent_title))
        raise Error, "Parent wiki page \"#{parent_title}\" is not imported" if apply && parent_title && !parent_id
        imported = page && !reset ? page.content.version : 0
        pending = versions(source, record.dig("project", "id"), record, imported)
        # Every version written is checked first, in the preview as well.
        authors = pending.to_h { |version| [version.fetch("version"), author_id(version, mappings)] }
        text = TextFormat.convert(record.fetch("text").to_s)
        new_attachments = record.fetch("attachments", []).reject { |attachment| page && store.find("wiki_attachments", attachment.fetch("id")) }
        # Mirror mode: local files whose source file is gone.
        listed = record.fetch("attachments", []).map { |attachment| attachment.fetch("id") }
        removed = page && Policy.source_wins? && store.respond_to?(:mappings) ?
          store.mappings("wiki_attachments").select { |source_id, local_id| !listed.include?(source_id) && page.attachments.exists?(id: local_id) } : []
        attachment_attributes = new_attachments.to_h { |attachment| [attachment.fetch("id"), Attachments.new.imported_attributes(attachment, mappings)] }
        moved = page && (parent_title ? parent_id && page.parent_id != parent_id : !page.parent_id.nil?)
        changed = page.nil? || reset || pending.any? || page.content.text != text || moved || new_attachments.any? || removed.any?
        event = { module: key, source_id: record.fetch("id"), destination_id: page&.id, action: page ? (changed ? "update" : "unchanged") : "create" }
        return event unless apply && changed
        # Imported pages and versions send no notification (inline jobs, deliveries off).
        Mailer.with_synched_deliveries do
          Mailer.with_deliveries(false) do
            MirrorMapping.transaction do
              if reset
                page.content&.versions&.delete_all
                page.content&.delete
                page.update_columns(title: title) unless page.title == title
                page.reload
              end
              removed.each do |source_id, local_id|
                page.attachments.find_by(id: local_id)&.destroy
                store.delete("wiki_attachments", source_id)
              end
              page ||= wiki.pages.new(title: title)
              pending.each { |version| write_version(page, version, authors.fetch(version.fetch("version"))) }
              page.update_columns(created_on: Time.iso8601(record.fetch("created_on"))) if imported.zero?
              rewrite_current_text(page.content, text) unless page.content.text == text
              page.update_columns(parent_id: parent_id) unless page.parent_id == parent_id
              new_attachments.each do |attachment|
                attributes = attachment_attributes.fetch(attachment.fetch("id"))
                local = Attachments.new.import(attachment, attributes, page, source)
                store.save("wiki_attachments", attachment.fetch("id"), "destination_id" => local.id,
                  "source_fingerprint" => digest(attributes), "destination_fingerprint" => digest(Attachments.new.local_attributes(local)))
              end
              page.reload
              store.save(key, record.fetch("id"), "destination_id" => page.id,
                "source_fingerprint" => digest(record.slice("title", "version", "updated_on")), "destination_fingerprint" => digest(local_state(page)))
            end
          end
        end
        event.merge(destination_id: page.id)
      end

      # A page renamed on the source answers under its new title: the old one is gone.
      def source_state(client, source_id, destination_id, source_project_id:, project_id:)
        page = WikiPage.find_by(id: destination_id)
        return "deleted" unless page
        found = client.get("#{page_path(source_project_id, page.title)}.json").fetch("wiki_page")
        found.fetch("title").casecmp?(page.title) ? "present" : "deleted"
      rescue Error => error
        return "deleted" if error.message.include?("HTTP 404")
        return "hidden" if error.message.include?("HTTP 403")
        raise
      end

      def delete_local(destination_id, project_id)
        page = WikiPage.find_by(id: destination_id)
        page.destroy if page && page.wiki.project_id == project_id
      end

      private

      def digest(value); Digest::SHA256.hexdigest(JSON.generate(value)); end

      def author_id(version, mappings)
        reference = version["author"]
        (reference && Users.new.resolve(mappings, reference.fetch("id"))) || User.anonymous.id
      end

      def local_state(page)
        content = page.content
        { "title" => page.title, "parent_id" => page.parent_id, "version" => content&.version,
          "text" => Digest::SHA256.hexdigest(content&.text.to_s) }
      end

      # Saving the content records a local version; its number and date are then
      # set to the source ones (deleted source versions leave the same gaps).
      def write_version(page, version, author)
        content = page.content || (page.new_record? ? WikiContent.new : page.build_content)
        content.assign_attributes(text: TextFormat.convert(version.fetch("text").to_s), comments: version["comments"].to_s,
          author_id: author, updated_on: Time.iso8601(version.fetch("updated_on")))
        if page.new_record?
          page.content = content
          page.save!
        else
          content.save!
        end
        number = Integer(version.fetch("version"))
        content.versions.where(version: content.version).update_all(version: number)
        content.update_columns(version: number)
      end

      # Issue references resolved later in the run: the current text is rewritten in
      # place, without a new version.
      def rewrite_current_text(content, text)
        current = content.versions.find_by(version: content.version)
        content.update_columns(text: text)
        return unless current
        current.text = text
        current.save!(touch: false)
      end
    end
  end
end
