# frozen_string_literal: true
# File: redmine_mirror/test/unit/mirror_demo_modules_test.rb
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
# Import the demo source project module by module, then again.

require_relative "../test_helper"
require_relative "../mirror_demo_source"

# The modules that write locally, on the demo project of test/fixtures/mirror_demo: each
# imports without error, then a second pass finds everything unchanged. The issues module
# writes through the REST API (two-instance smokes): one local issue per source issue
# stands for it here.
class MirrorDemoModulesTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :enumerations,
    :trackers, :projects_trackers, :issue_statuses, :versions, :wikis, :wiki_pages, :wiki_contents, :documents, :news

  DESTINATION_URL = "https://destination.example"
  # Local users given to the six source users, in their source ID order.
  LOCAL_USERS = %w[2 3 4 7 8 9].freeze

  def setup
    @previous_url = ENV["MIRROR_DESTINATION_URL"]
    ENV["MIRROR_DESTINATION_URL"] = DESTINATION_URL
    @project = Project.find(1)
    %i[mirror wiki documents files news].each { |name| @project.enable_module!(name) }
    @source = MirrorDemoSource.new
    setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example", source_project_id: @source.project_id)
    setting.selected_modules = %w[issue_tracking]
    setting.api_key = "reader-api-key"
    setting.save!
    key = Digest::SHA256.hexdigest(JSON.generate(["https://source.example", @source.project_id, DESTINATION_URL, @project.id]))
    @store = RedmineMirror::DatabaseStore.new(key, project_id: @project.id)
    @lookup = ->(module_key, id) { @store.find(module_key, id)&.fetch("destination_id") }
    catalog = RedmineMirror::SourceCatalog.new(client: @source, project_id: @source.project_id,
      # The demo source has no Project Enumerations plugin and no repository.
      adapters: RedmineMirror::REGISTRY.resolve(RedmineMirror::REGISTRY.keys - %w[project_enumerations repositories])).fetch
    local = { "role" => "1", "tracker" => "1", "status" => "1", "priority" => "4", "activity" => "9",
      "document_category" => DocumentCategory.first.id.to_s }
    @mappings = local.to_h { |kind, id| [kind, catalog.fetch(kind).keys.to_h { |source_id| [source_id, id] }] }
    @mappings["user"] = catalog.fetch("user").keys.sort_by(&:to_i).zip(LOCAL_USERS).to_h
  end

  def teardown
    ENV["MIRROR_DESTINATION_URL"] = @previous_url
  end

  def sync(key)
    adapter = RedmineMirror::REGISTRY[key]
    events = adapter.records(@source, @source.project_id).map do |record|
      adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store, source: @source, apply: true)
    end
    events.map { |event| event.fetch(:action) }.tally
  end

  def import_issues
    RedmineMirror::Adapters::Issues.new.records(@source, @source.project_id).each do |record|
      issue = Issue.create!(project: @project, tracker_id: 1, author_id: 2, status_id: 1, priority_id: 4, subject: record.fetch("subject"))
      @store.save("issue_tracking", record.fetch("id"), "destination_id" => issue.id, "source_fingerprint" => "-", "destination_fingerprint" => "-")
    end
  end

  def assert_imported_then_unchanged(expected)
    expected.each do |key, actions|
      assert_equal actions, sync(key), "first pass of #{key}"
      again = actions.each_with_object(Hash.new(0)) { |(action, count), sums| sums[action == "ignored" ? action : "unchanged"] += count }
      assert_equal again, sync(key), "second pass of #{key}"
    end
  end

  # Files of the Files module: on the project or on one of its versions.
  def project_files
    Attachment.where(container_type: "Project", container_id: @project.id).or(Attachment.where(container_type: "Version", container_id: @project.versions.select(:id))).count
  end

  def test_project_references_wiki_documents_files_news_and_queries
    before = [@project.wiki.pages.count, project_files, @project.news.count]
    with_settings attachment_max_size: 10_240, notified_events: %w[wiki_content_added document_added news_added file_added] do
      ActionMailer::Base.deliveries.clear
      assert_imported_then_unchanged("issue_categories" => { "create" => 4 }, "project_versions" => { "create" => 4 },
        # jsmith and dlopper are already members: one keeps its roles, one gets more.
        "project_members" => { "create" => 4, "update" => 1, "unchanged" => 1 }, "wiki" => { "create" => 12 }, "documents" => { "create" => 5 },
        "project_files" => { "create" => 4 }, "news" => { "create" => 4 },
        # Scrum and tag filters, a named subproject and an agile board have no local equivalent.
        "project_queries" => { "create" => 7, "ignored" => 4 })
      assert_empty ActionMailer::Base.deliveries
    end
    assert_equal [12, 4, 4], [@project.wiki.pages.count, project_files, @project.news.count].zip(before).map { |now, was| now - was }
    # Titles with a number, an accent or an apostrophe.
    %w[Meetings_2026 Café_menu Users'_guide].each { |title| assert @project.wiki.find_page(title), title }
    assert_empty @source.unrecorded
  end

  def test_issue_history_attachments_relations_hierarchy_and_watchers
    with_settings attachment_max_size: 10_240 do
      import_issues
      # Journals holding only relation changes are left to the relations module; the
      # relation to the partner portal waits for that project. Hierarchy and watchers
      # update the issues that have a parent or watchers.
      assert_imported_then_unchanged("issue_journals" => { "create" => 131, "ignored" => 10 }, "issue_attachments" => { "create" => 23 },
        "issue_relations" => { "create" => 5, "ignored" => 1 }, "issue_hierarchy" => { "update" => 4, "unchanged" => 49 },
        "issue_watchers" => { "update" => 3, "unchanged" => 50 })
    end
    assert_equal 4, Issue.where(project_id: @project.id).where.not(parent_id: nil).count
    # The 5 MB file arrives whole: its generated bytes have the declared size.
    assert_equal 5_242_880, Attachment.where(container_type: "Issue").maximum(:filesize)
    assert_empty @source.unrecorded
  end
end
