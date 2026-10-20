# frozen_string_literal: true
# File: redmine_mirror/test/functional/mirror_settings_controller_test.rb
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
require "minitest/mock"

class MirrorSettingsControllerTest < ActionController::TestCase
  tests MirrorSettingsController
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking time_tracking]
    @setting.api_key = "private-api-key"
    @setting.source_catalog = { "tracker" => { "1" => "Remote tracker" }, "status" => { "1" => "Open" },
      "priority" => { "1" => "Normal" }, "user" => { "7" => "Remote Alice" }, "activity" => { "9" => "Development" } }
    @setting.save!
    @request.session[:user_id] = 1
  end

  # The configuration moved to the project settings, the operations to the Mirror page.
  def test_former_links_lead_to_their_new_place
    get :show, params: { project_id: @project.identifier }
    assert_redirected_to "/projects/ecookbook/settings/mirror"
    get :show, params: { project_id: @project.identifier, tab: "users", all_references: "1" }
    assert_redirected_to "/projects/ecookbook/settings/mirror?all_references=1&mirror_tab=users"
    get :show, params: { project_id: @project.identifier, tab: "synchronization" }
    assert_redirected_to "/projects/ecookbook/mirror"
    get :show, params: { project_id: @project.identifier, tab: "conflicts", conflict_status: "open" }
    assert_redirected_to "/projects/ecookbook/mirror?conflict_status=open&tab=conflicts"
  end

  def test_relation_policy_is_saved_per_project
    @setting.selected_modules = ["issue_relations"]
    @setting.save!
    @request.session[:user_id] = 1
    patch :update_mappings, params: { project_id: @project.id, module_key: "issue_relations",
      module_options: { missing_target: "note" } }
    assert_response :redirect
    assert_equal "note", @setting.reload.module_options.dig("issue_relations", "missing_target")
    patch :update_mappings, params: { project_id: @project.id, module_key: "issue_relations",
      module_options: { missing_target: "invalid" } }
    assert_equal "note", @setting.reload.module_options.dig("issue_relations", "missing_target")
  end

  def test_saves_mapping_for_this_project
    tracker = @project.trackers.first
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "issue_tracking",
      mappings: { tracker: { "1" => tracker.id.to_s } } }
    assert_response :redirect
    row = @project.mirror_reference_mappings.find_by!(reference_type: "tracker", source_id: 1)
    assert_equal tracker.id, row.destination_id
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users", mappings: { user: { "7" => "anonymous" } } }
    anonymous = @project.mirror_reference_mappings.find_by!(reference_type: "user", source_id: 7)
    assert_equal "anonymous", anonymous.mode
    assert_nil anonymous.destination_id
    assert_equal "anonymous", @setting.reload.synchronization_config(destination_url: "https://local.example").dig("mappings", "user", "7")
  end

  # A checked special choice wins over the row's field; one the table does not offer is refused.
  def test_checked_special_choice_wins_over_the_field
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users",
      mappings: { user: { "7" => "2" } }, special_mappings: { user: { "7" => "anonymous" } }, mirror_filter: "mapped" }
    assert_redirected_to "/projects/ecookbook/settings/mirror?mirror_filter=mapped&mirror_tab=users"
    assert_equal "anonymous", @project.mirror_reference_mappings.find_by!(reference_type: "user", source_id: 7).mode
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users",
      mappings: { user: { "7" => "" } }, special_mappings: { user: { "7" => "ignore" } } }
    assert flash[:error].present?
    assert_equal "anonymous", @project.mirror_reference_mappings.find_by!(reference_type: "user", source_id: 7).mode
  end

  # A tracker's checkbox leaves its issues out; a priority offers no such choice.
  def test_tracker_checkbox_ignores_its_issues
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "issue_tracking",
      mappings: { tracker: { "1" => @project.trackers.first.id.to_s } }, special_mappings: { tracker: { "1" => "ignore" } } }
    row = @project.mirror_reference_mappings.find_by!(reference_type: "tracker", source_id: 1)
    assert_equal ["ignore", nil], [row.mode, row.destination_id]
    assert_equal "ignore", @setting.reload.synchronization_config(destination_url: "https://local.example").dig("mappings", "tracker", "1")
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "issue_tracking",
      mappings: { priority: { "1" => "" } }, special_mappings: { priority: { "1" => "ignore" } } }
    assert flash[:error].present?
    assert_nil @project.mirror_reference_mappings.find_by(reference_type: "priority", source_id: 1)
  end

  def test_rejects_anonymous_tracker_and_rolls_back_other_mappings
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "issue_tracking",
      mappings: { status: { "1" => IssueStatus.first.id.to_s }, tracker: { "1" => "anonymous" } } }
    assert_response :redirect
    assert_equal 0, @project.mirror_reference_mappings.count
    assert flash[:error].present?
  end

  def test_rejects_reference_from_another_module
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "issue_tracking",
      mappings: { activity: { "9" => "1" } } }
    assert_equal 0, @project.mirror_reference_mappings.count
    assert flash[:error].present?
  end

  def test_rejects_unknown_source_reference
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users",
      mappings: { user: { "999" => "anonymous" } } }
    assert_equal 0, @project.mirror_reference_mappings.count
    assert flash[:error].present?
  end

  def test_member_without_manage_permission_cannot_read_or_write
    Role.all.each { |role| %i[manage_mirror select_project_modules].each { |permission| role.remove_permission!(permission) } }
    @request.session[:user_id] = 2
    get :show, params: { project_id: @project.identifier }
    assert_response :forbidden
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users",
      mappings: { user: { "7" => "anonymous" } } }
    assert_response :forbidden
    assert_equal 0, @project.mirror_reference_mappings.count
  end

  def test_allowed_member_can_map_but_cannot_rebind_the_connection
    Role.givable.each { |role| role.add_permission!(:manage_mirror) }
    @request.session[:user_id] = 2
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users",
      mappings: { user: { "7" => "anonymous" } } }
    assert_response :redirect
    patch :update_connection, params: { project_id: @project.identifier,
      connection: { source_url: "https://other.example", source_project_id: 1 } }
    assert_redirected_to "/projects/ecookbook/settings/mirror"
    assert flash[:error]
    assert_equal "https://source.example/redmine", @setting.reload.source_url
  end

  # Non-administrators connect only to a source Redmine an administrator allowed.
  def test_members_connect_only_to_allowed_sources
    @setting.destroy
    @request.session[:user_id] = 2
    connection = { source_url: "https://source.example/redmine/", source_project_id: "legacy-app", api_key: "source-key", modules: ["issue_tracking"] }
    RedmineMirror::Client.stub(:new, source_project_client(34, "legacy-app")) do
      patch :update_connection, params: { project_id: @project.identifier, connection: connection }
      assert_equal "This source Redmine URL is not allowed. An administrator lists the allowed sources in the Redmine Mirror plugin configuration.", flash[:error]
      assert_nil @project.reload.mirror_project_setting
      with_settings(plugin_redmine_mirror: { "allowed_source_urls" => "https://other.example\nhttps://source.example/redmine\n" }) do
        patch :update_connection, params: { project_id: @project.identifier, connection: connection }
      end
    end
    assert_equal "https://source.example/redmine", @project.reload.mirror_project_setting.source_url
  end

  def test_cross_project_write_is_denied
    Role.givable.each { |role| role.add_permission!(:manage_mirror) }
    other = Project.create!(name: "Private target", identifier: "other-mirror", is_public: false, enabled_module_names: ["mirror"])
    @request.session[:user_id] = 2
    patch :update_mappings, params: { project_id: other.id, module_key: "issue_tracking", mappings: { user: { "7" => "anonymous" } } }
    assert_response :forbidden
    assert_equal 0, MirrorReferenceMapping.count
  end

  def test_time_module_accepts_active_project_member_for_anonymous_time
    user = @project.users.active.first
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users",
      mappings: { user: { "7" => "anonymous" } }, module_options: { anonymous_user_id: user.id.to_s } }
    assert_response :redirect
    assert_equal user.id, @setting.reload.module_options.dig("users", "anonymous_user_id")
  end

  def test_rejects_time_fallback_outside_project
    patch :update_mappings, params: { project_id: @project.identifier, module_key: "users",
      mappings: { user: { "7" => "anonymous" } }, module_options: { anonymous_user_id: "99999" } }
    assert flash[:error].present?
    assert_equal 0, MirrorReferenceMapping.count
  end

  def test_saving_connection_keeps_key_and_expands_dependencies
    catalog = Object.new
    def catalog.fetch; { "user" => { "7" => "Alice" } }; end
    RedmineMirror::SourceCatalog.stub(:new, catalog) do
      patch :update_connection, params: { project_id: @project.identifier,
        connection: { source_url: @setting.source_url, source_project_id: 12, api_key: "", modules: ["", "time_tracking"] } }
    end
    assert_response :redirect
    assert_equal %w[users issue_tracking time_tracking], @setting.reload.selected_modules
    assert_equal "private-api-key", @setting.api_key
  end

  # Source REST client double answering the project lookup.
  def source_project_client(id, identifier)
    client = Object.new
    client.define_singleton_method(:get) do |path, _params = {}|
      raise RedmineMirror::Error, "Redmine API returned HTTP 404" unless ["projects/#{id}.json", "projects/#{identifier}.json"].include?(path)
      { "project" => { "id" => id, "identifier" => identifier } }
    end
    client
  end

  def test_new_connection_accepts_the_source_project_identifier
    @setting.destroy
    catalog = Object.new
    def catalog.fetch; {}; end
    RedmineMirror::Client.stub(:new, source_project_client(34, "legacy-app")) do
      RedmineMirror::SourceCatalog.stub(:new, catalog) do
        patch :update_connection, params: { project_id: @project.identifier,
          connection: { source_url: "https://source.example/redmine", source_project_id: "legacy-app", api_key: "source-key", modules: ["issue_tracking"] } }
      end
    end
    assert_response :redirect
    setting = @project.reload.mirror_project_setting
    assert_equal [34, "legacy-app"], [setting.source_project_id, setting.source_project_identifier]
  end

  def test_unknown_or_invalid_source_project_is_refused
    @setting.destroy
    RedmineMirror::Client.stub(:new, source_project_client(34, "legacy-app")) do
      ["other-app", "../admin", "Legacy"].each do |reference|
        patch :update_connection, params: { project_id: @project.identifier,
          connection: { source_url: "https://source.example/redmine", source_project_id: reference, api_key: "source-key", modules: ["issue_tracking"] } }
        assert flash[:error]
      end
    end
    assert_nil @project.reload.mirror_project_setting
  end

  def test_connection_identifier_must_designate_the_same_source_project
    RedmineMirror::Client.stub(:new, source_project_client(99, "another-app")) do
      patch :update_connection, params: { project_id: @project.identifier,
        connection: { source_url: @setting.source_url, source_project_id: "another-app", modules: ["issue_tracking"] } }
    end
    assert flash[:error]
    assert_equal 12, @setting.reload.source_project_id
  end

  def test_saving_requests_a_catalog_refresh_done_by_the_worker
    catalog = Object.new
    setting = @setting
    catalog.define_singleton_method(:fetch) do |progress: nil|
      progress.call(1, 2, "issue_tracking", 0)
      setting.reload
      raise "progress not saved" unless setting.catalog_status == "refreshing" && setting.catalog_progress["module"] == "issue_tracking"
      { "user" => { "7" => "Alice" } }
    end
    RedmineMirror::SourceCatalog.stub(:new, ->(*) { raise "the web request must not read the source" }) do
      patch :update_connection, params: { project_id: @project.identifier,
        connection: { source_url: @setting.source_url, source_project_id: 12, modules: ["issue_tracking"] } }
    end
    assert_response :redirect
    assert_equal "pending", @setting.reload.catalog_status
    RedmineMirror::Client.stub(:new, source_project_client(12, "legacy-app")) do
      RedmineMirror::SourceCatalog.stub(:new, catalog) { RedmineMirror::Synchronization.refresh_catalogs }
    end
    @setting.reload
    assert_equal ["ready", { "7" => "Alice" }, "legacy-app"], [@setting.catalog_status, @setting.source_catalog["user"], @setting.source_project_identifier]
    assert_empty @setting.catalog_progress
  end

  def test_connection_cannot_be_rebound_to_another_source
    patch :update_connection, params: { project_id: @project.identifier,
      connection: { source_url: "https://other.example", source_project_id: 12, modules: ["issue_tracking"] } }
    assert flash[:error]
    assert_equal "https://source.example/redmine", @setting.reload.source_url
  end
  def test_custom_field_mappings_and_values_are_project_scoped
    field = IssueCustomField.create!(name: "Local list", field_format: "list", possible_values: ["Local A"], is_for_all: true)
    @setting.selected_modules = ["issue_custom_fields"]
    @setting.source_catalog = { "custom_field" => { "900" => "Remote list" }, "custom_field_definitions" => {
      "900" => { "field_format" => "list", "multiple" => false, "possible_values" => [{ "value" => "Remote [A]", "label" => "Remote [A]" }] } } }
    @setting.save!
    value_key = RedmineMirror::Adapters::CustomFields.new.value_key("Remote [A]")
    patch :update_mappings, params: { project_id: @project.id, module_key: "issue_custom_fields", mappings: { custom_field: { "900" => field.id.to_s } }, module_options: { value_mappings: { "900" => { value_key => "Local A" } } } }
    assert_redirected_to "/projects/#{@project.identifier}/settings/mirror?mirror_tab=issue_custom_fields"
    assert_equal field.id, @project.mirror_reference_mappings.find_by!(reference_type: "custom_field", source_id: 900).destination_id
    assert_equal "Local A", @setting.reload.module_options.dig("issue_custom_fields", "value_mappings", "900", value_key)
    patch :update_mappings, params: { project_id: @project.id, module_key: "issue_custom_fields", mappings: { custom_field: { "999" => field.id.to_s } } }
    assert flash[:error]
    assert_nil @project.mirror_reference_mappings.find_by(reference_type: "custom_field", source_id: 999)
  end

  def test_ignore_is_persisted_only_for_custom_fields
    @setting.selected_modules = ["issue_custom_fields"]
    @setting.source_catalog = @setting.source_catalog.merge("custom_field" => { "900" => "Remote field" })
    @setting.save!
    patch :update_mappings, params: { project_id: @project.id, module_key: "issue_custom_fields", mappings: { custom_field: { "900" => "ignore" } } }
    row = @project.mirror_reference_mappings.find_by!(reference_type: "custom_field", source_id: 900)
    assert_equal "ignore", row.mode
    assert_nil row.destination_id
    assert_equal "ignore", @setting.synchronization_config(destination_url: "https://local.example").dig("mappings", "custom_field", "900")
    patch :update_mappings, params: { project_id: @project.id, module_key: "users", mappings: { user: { "7" => "ignore" } } }
    assert flash[:error]
    assert_nil @project.mirror_reference_mappings.find_by(reference_type: "user", source_id: 7)
  end

end
