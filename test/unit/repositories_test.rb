# frozen_string_literal: true
# File: redmine_mirror/test/unit/repositories_test.rb
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
# Verify Mirror behavior, project boundaries and repeatable synchronization.

require_relative "../test_helper"
require "tmpdir"

class MirrorRepositoriesTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issues, :issue_statuses, :trackers, :projects_trackers, :enumerations, :enabled_modules,
    :members, :member_roles, :roles

  class Store
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
  end

  # A source sharing one Git repository whose revision is linked to source issue 501.
  class Source
    attr_reader :requests
    def initialize(rows, links, credentials: nil); @rows = rows; @links = links; @credentials = credentials; @requests = []; end
    def get(path, params = {})
      @requests << [path, params]
      # Like Mirror source: the credentials only when asked for (and shared).
      if path.end_with?("repositories.json")
        return { "repositories" => @rows.map { |entry| params["credentials"] == "1" && @credentials ? entry.merge(@credentials) : entry } }
      end
      { "repository_links" => { "total_count" => @links.size, "offset" => params["offset"].to_i, "links" => @links.drop(params["offset"].to_i).first(1) } }
    end
  end

  def setup
    @project = Project.find(1)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 9)
    @setting.selected_modules = %w[issue_tracking repositories]
    @setting.api_key = "key"
    @setting.save!
    @adapter = RedmineMirror::Adapters::Repositories.new
    @dir = Dir.mktmpdir("mirror-git")
    # Redmine reads bare Git repositories: a work tree, then its bare copy "on the server".
    work = File.join(@dir, "work")
    @path = File.join(@dir, "copied", "app.git")
    FileUtils.mkdir_p(work)
    git = ->(*args) { system("git", "-C", work, "-c", "user.email=dev@example.com", "-c", "user.name=Dev", *args, out: File::NULL, err: File::NULL) || raise("git #{args.first} failed") }
    git.call("init", "-q", "-b", "main")
    File.write(File.join(work, "a.txt"), "a")
    git.call("add", "a.txt")
    git.call("commit", "-q", "-m", "First change refs #1")
    @revision = `git -C #{work} rev-parse HEAD`.strip
    system("git", "clone", "-q", "--bare", work, @path, out: File::NULL, err: File::NULL) || raise("git clone failed")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def row(**extra)
    { "project" => { "id" => 9 }, "id" => 5, "scm" => "Git", "identifier" => "app", "is_default" => true,
      "url" => "/old/server/app.git", "root_url" => "", "path_encoding" => "", "log_encoding" => nil,
      "report_last_commit" => true, "changesets_count" => 1 }.merge(extra.transform_keys(&:to_s))
  end

  def run_record(record, source, store = Store.new, lookup: ->(key, id) { key == "issue_tracking" && id == 501 ? 3 : nil })
    @adapter.synchronize(record, project_id: @project.id, mappings: {}, lookup: lookup, store: store, source: source, apply: true)
  end

  def test_recreates_the_repository_at_its_new_path_and_links_from_the_source
    @setting.update!(module_options: { "repositories" => @adapter.configuration_options({ "path_rewrites" => "/old/server => #{@dir}/copied" }, @project) })
    source = Source.new([row], [{ "revision" => @revision, "issue_ids" => [501] }])
    with_settings(enabled_scm: %w[Git Subversion]) do
      store = Store.new
      event = run_record(row, source, store)
      assert_equal "create", event[:action]
      repository = Repository.find(event[:destination_id])
      assert_equal [@path, "app", true], [repository.url, repository.identifier, repository.is_default]
      changeset = repository.changesets.find_by!(revision: @revision)
      # Redmine linked "refs #1" to this Redmine's issue 1; the source link wins.
      assert_equal [3], changeset.issue_ids
      assert_predicate repository.login.to_s, :empty?
      assert_equal "unchanged", run_record(row, source, store)[:action]
    end
  end

  def test_credentials_are_kept_only_when_the_project_asks
    source = Source.new([row(url: @path)], [], credentials: { "login" => "svc", "password" => "secret" })
    record = row(url: @path)
    with_settings(enabled_scm: %w[Git]) do
      repository = Repository.find(run_record(record, source)[:destination_id])
      assert_predicate repository.password.to_s, :empty?
      # Never asked for while the project does not keep them.
      assert source.requests.none? { |_, params| params["credentials"] }
      repository.destroy
      @setting.update!(module_options: { "repositories" => @adapter.configuration_options({ "credentials" => "1" }, @project) })
      repository = Repository.find(run_record(record, source)[:destination_id])
      assert_equal %w[svc secret], [repository.login, repository.password]
    end
  end

  def test_a_disabled_scm_or_a_missing_copy_is_explained
    source = Source.new([row], [])
    with_settings(enabled_scm: %w[Subversion]) do
      assert_match "SCM is not enabled", assert_raises(RedmineMirror::Error) { run_record(row, source) }.message
    end
    with_settings(enabled_scm: %w[Git]) do
      assert_match "copy it there first", assert_raises(RedmineMirror::Error) { run_record(row(url: "/nowhere/app.git"), source) }.message
    end
  end

  def test_options_are_checked
    assert_raises(RedmineMirror::Error) { @adapter.configuration_options({ "path_rewrites" => "no arrow" }, @project) }
    assert_raises(RedmineMirror::Error) { @adapter.configuration_options({ "other" => "1" }, @project) }
    assert_equal({ "path_rewrites" => "/a => /b", "credentials" => "0", "fetch_changesets" => "1" }, @adapter.configuration_options({ "path_rewrites" => " /a => /b \n\n" }, @project))
  end
end
