# frozen_string_literal: true
# File: redmine_mirror/test/unit/adapter_extension_test.rb
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
# Verify the external adapter contract: removed modules and extension links.

require "minitest/mock"
require_relative "../test_helper"

class MirrorAdapterExtensionTest < ActionView::TestCase
  include MirrorHelper
  fixtures :projects, :users, :enabled_modules

  class ExternalTable < RedmineMirror::MappingTable
    def local_path(id, _project); "/external/#{id}"; end
    def remote_path(id, _setting); "external/#{id}.html"; end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking]
    @setting.api_key = "private-api-key"
    @setting.save!
  end

  # A plugin removed after configuration must not break the pages, nor let a run
  # proceed silently without one of its modules.
  def test_removed_module_is_reported_and_blocks_synchronization
    @setting.update_column(:selected_modules, JSON.generate(%w[users issue_tracking removed_plugin_data]))
    @setting.reload
    assert_equal %w[users issue_tracking], @setting.selected_modules
    assert_equal %w[removed_plugin_data], @setting.unavailable_modules
    assert_not @setting.valid?
    error = assert_raises(RedmineMirror::Error) { RedmineMirror::Synchronization.enqueue(@setting, apply: false, trigger: "manual") }
    assert_includes error.message, "removed_plugin_data"
    assert_equal 0, @project.mirror_sync_runs.count
  end

  # A RedmineMirror::Version constant would hide Redmine's Version model in every adapter.
  def test_mirror_namespace_does_not_hide_redmine_models
    assert_not RedmineMirror.const_defined?(:Version, false)
    assert_equal ::Version, RedmineMirror::Adapters::Versions.new.model
    assert_equal ::IssueCategory, RedmineMirror::Adapters::Categories.new.model
  end

  def test_external_reference_tables_provide_local_and_remote_links
    table = ExternalTable.new("external_level")
    RedmineMirror::REGISTRY.stub(:mapping_table, ->(key) { key == "external_level" ? table : nil }) do
      assert_includes mirror_object_link("external_level", 4), 'href="/external/4"'
      assert_includes mirror_object_link("external_level", 4, source_url: @setting.source_url), 'href="https://source.example/redmine/external/4.html"'
      assert_equal "5", mirror_object_link("unknown_reference", 5)
    end
  end
end
