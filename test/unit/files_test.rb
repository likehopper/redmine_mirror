# frozen_string_literal: true
# File: redmine_mirror/test/unit/files_test.rb
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
# Verify the Files module: container, metadata, downloads, waiting versions, conflicts and mirror mode.

require_relative "../test_helper"

class MirrorFilesTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :versions

  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
    def delete(key, id); @rows.delete([key, id]); end
    def mappings(key); @rows.filter_map { |(row_key, id), values| [id, values.fetch("destination_id")] if row_key == key }; end
  end

  FILE = "Installer\n"

  class Source
    attr_accessor :files
    attr_reader :downloads
    def initialize
      @files = [
        { "id" => 601, "filename" => "setup.txt", "filesize" => FILE.bytesize, "content_type" => "text/plain", "description" => "Installer",
          "author" => { "id" => 7, "name" => "Remote" }, "created_on" => "2026-03-04T09:00:00Z", "digest" => "x", "downloads" => 12 },
        { "id" => 602, "filename" => "release.txt", "filesize" => FILE.bytesize, "content_type" => "text/plain", "description" => "",
          "author" => { "id" => 7, "name" => "Remote" }, "created_on" => "2026-03-05T09:00:00Z", "digest" => "y", "downloads" => 3,
          "version" => { "id" => 81, "name" => "1.0" } }
      ]
    end

    def get(path, _params = {})
      case path
      when "projects/9/files.json" then { "files" => @files }
      when %r{\Aattachments/\d+\.json\z} then raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"
      else raise "Unexpected #{path}"
      end
    end

    def download_attachment(id, max_bytes:, path: nil)
      (@downloads ||= []) << [id, path]
      FILE.dup
    end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:files)
    @store = Store.new
    @source = Source.new
    @adapter = RedmineMirror::Adapters::Files.new
    @mappings = { "user" => { "7" => "2" } }
    # Source version 81 is local version 2 of project 1.
    @store.save("project_versions", 81, "destination_id" => 2)
    @lookup = ->(key, id) { @store.find(key, id)&.fetch("destination_id") }
  end

  def sync(apply: true)
    @adapter.records(@source, 9).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store, source: @source, apply: apply)
    end
  end

  def imported(source_id)
    Attachment.find(@store.find("project_files", source_id).fetch("destination_id"))
  end

  def test_files_land_on_the_project_or_their_version_with_metadata_and_downloads
    with_settings attachment_max_size: 1024 do
      assert_no_difference "Attachment.count" do
        assert_equal %w[create create], sync(apply: false).map { |event| event[:action] }
      end
      sync
      project_file = imported(601)
      assert_equal [@project, "setup.txt", "Installer", 2, Time.utc(2026, 3, 4, 9), 12],
        [project_file.container, project_file.filename, project_file.description, project_file.author_id, project_file.created_on, project_file.downloads]
      assert_equal FILE, File.read(project_file.diskfile)
      version_file = imported(602)
      assert_equal [Version.find(2), 3], [version_file.container, version_file.downloads]
      assert_equal [[601, nil], [602, nil]], @source.downloads
    end
    # Local downloads are not a modification.
    imported(601).increment!(:downloads)
    assert_equal %w[unchanged unchanged], sync.map { |event| event[:action] }
  end

  def test_source_description_and_version_changes_update_in_place
    with_settings attachment_max_size: 1024 do
      sync
      local_id = imported(601).id
      @source.files.first.merge!("description" => "Installer v2", "version" => { "id" => 81, "name" => "1.0" })
      assert_equal %w[update unchanged], sync.map { |event| event[:action] }
      file = imported(601)
      assert_equal [local_id, "Installer v2", Version.find(2), 12], [file.id, file.description, file.container, file.downloads]
      assert_equal 2, @source.downloads.size
    end
  end

  def test_a_file_waits_for_its_version
    with_settings attachment_max_size: 1024 do
      @store.delete("project_versions", 81)
      events = sync
      assert_equal %w[create ignored], events.map { |event| event[:action] }
      assert_match(/Version "1.0" \(source ID 81\) not imported yet/, events.last[:reason])
      assert_nil @store.find("project_files", 602)
      @store.save("project_versions", 81, "destination_id" => 2)
      assert_equal %w[unchanged create], sync.map { |event| event[:action] }
    end
  end

  def test_local_edit_is_a_conflict_unless_the_source_wins
    with_settings attachment_max_size: 1024 do
      sync
      imported(601).update!(description: "Local")
      error = assert_raises(RedmineMirror::Error) { sync }
      assert_match(/Local modification detected for file setup.txt/, error.message)
      RedmineMirror::Policy.with(source_wins: true) { sync }
      assert_equal "Installer", imported(601).description
    end
  end

  def test_deletion_is_confirmed_by_the_source
    with_settings attachment_max_size: 1024 do
      sync
      file = imported(602)
      assert_equal "deleted", @adapter.source_state(@source, 602, file.id, source_project_id: 9, project_id: @project.id)
      @adapter.delete_local(file.id, @project.id)
      assert_nil Attachment.find_by(id: file.id)
    end
  end

  def test_missing_user_disabled_modules_and_hidden_files_fail
    @mappings = { "user" => {} }
    assert_raises(RedmineMirror::Error) { sync(apply: false) }
    @mappings = { "user" => { "7" => "2" } }
    @project.disable_module!(:files)
    assert_match(/Enable the Files module on the destination project/, assert_raises(RedmineMirror::Error) { sync(apply: false) }.message)
    source = Object.new
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path}"; end
    message = assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message
    assert_match(/enable the Files module on the source project/, message)
    assert_equal ["source_permission", { "path" => "projects/9/files.json" }], RedmineMirror::Diagnosis.cause(message)
  end
end
