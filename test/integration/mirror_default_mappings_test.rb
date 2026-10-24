# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_default_mappings_test.rb
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

class MirrorDefaultMappingsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers, :projects_trackers,
    :issue_statuses, :enumerations

  SOURCE = "https://source.example/redmine"

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: SOURCE, source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking issue_custom_fields time_tracking]
    @setting.api_key = "private-api-key"
    # "Feature" has a rule, "Bug" a local namesake, "Story" neither; status 9 is not used.
    @setting.source_catalog = {
      "tracker" => { "1" => "Bug", "2" => "Feature", "3" => "Story" }, "tracker_used" => %w[1 2 3],
      "status" => { "7" => "Archived step", "8" => "Résolu", "9" => "Unused status" }, "status_used" => %w[7 8],
      "priority" => { "4" => "Normal priority" }, "activity" => { "5" => "development web" },
      "user" => { "70" => "Departed user" }, "user_used" => ["70"]
    }
    @setting.save!
    User.current = nil
  end

  def rule(type, name, destination = nil, **attributes)
    MirrorDefaultMapping.create!({ reference_type: type, source_name: name, destination_id: destination }.merge(attributes))
  end

  def mapping(type, source_id)
    @project.mirror_reference_mappings.find_by(reference_type: type, source_id: source_id)
  end

  def test_only_administrators_manage_defaults
    log_user("jsmith", "jsmith")
    get "/admin/mirror/defaults"
    assert_response 403
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "tracker", destination: "1" } }
    assert_response 403
    assert_equal 0, MirrorDefaultMapping.count
  end

  def test_administrator_adds_several_names_and_a_fallback
    log_user("admin", "admin")
    get "/admin/mirror/defaults"
    assert_response :success
    assert_select ".mirror-admin-sidebar a.selected", text: "Default correspondences"
    # Users only take a fallback.
    assert_select "#mirror-default-form-user textarea", count: 0
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "tracker", source_names: "Feature\nEnhancement\nfeature", destination: "2" } }
    assert_redirected_to "/admin/mirror/defaults#mirror-defaults-tracker"
    assert_equal [["Enhancement", 2], ["Feature", 2]], MirrorDefaultMapping.where(reference_type: "tracker").order(:source_key).pluck(:source_name, :destination_id)
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "status", source_names: "", destination: "ignore" } }
    assert MirrorDefaultMapping.find_by(reference_type: "status", source_key: nil, mode: "ignore")
    # Priorities cannot be ignored; an unknown destination is refused.
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "priority", source_names: "Low priority", destination: "ignore" } }
    assert flash[:error]
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "tracker", source_names: "Unknown tracker", destination: "999" } }
    assert flash[:error]
    # The same name and source again is refused.
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "tracker", source_names: "FEATURE", destination: "1" } }
    assert flash[:error]
    get "/admin/mirror/defaults"
    assert_select "#mirror-defaults-table-tracker tbody tr", count: 2
    assert_select "#mirror-defaults-table-status td", text: "Otherwise (fallback)"
    delete "/admin/mirror/defaults/#{MirrorDefaultMapping.find_by(source_name: 'Enhancement').id}"
    assert_equal 1, MirrorDefaultMapping.where(reference_type: "tracker").count
  end

  def test_reading_the_source_references_saves_the_defaults_into_the_project
    rule("tracker", "feature", 2)
    rule("tracker", nil, 3)
    rule("status", nil, nil, mode: "ignore")
    rule("status", "Resolu", 3)
    rule("status", "Resolu", 2, source_url: "#{SOURCE}/")
    rule("priority", "normal priority", 5)
    rule("activity", "Development web", 10)
    rule("user", nil, 4)
    @project.mirror_reference_mappings.create!(reference_type: "priority", source_id: 4, destination_id: 6)
    client = Object.new
    client.define_singleton_method(:get) { |_path| { "project" => { "id" => 12, "identifier" => "legacy" } } }
    catalog = @setting.source_catalog
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |progress: nil| catalog }
    @setting.request_catalog_refresh!
    RedmineMirror::Client.stub(:new, client) do
      RedmineMirror::SourceCatalog.stub(:new, fetcher) { RedmineMirror::Synchronization.refresh_catalogs }
    end
    assert_equal "ready", @setting.reload.catalog_status
    assert_equal [2, true], [mapping("tracker", 2).destination_id, mapping("tracker", 2).from_default]
    # "Bug" has a local namesake: left to the form's suggestion, not to the fallback.
    assert_nil mapping("tracker", 1)
    assert_equal 3, mapping("tracker", 3).destination_id
    # The rule for this source wins over the rule for any source; the fallback ignores.
    assert_equal 2, mapping("status", 8).destination_id
    assert_equal "ignore", mapping("status", 7).mode
    # The fallback leaves the references the project does not use.
    assert_nil mapping("status", 9)
    # A saved correspondence is never changed.
    assert_equal [6, false], [mapping("priority", 4).destination_id, mapping("priority", 4).from_default]
    assert_equal 10, mapping("activity", 5).destination_id
    # A generic account need not be a project member.
    refute @project.users.include?(User.find(4))
    assert_equal 4, mapping("user", 70).destination_id
  end

  def test_project_form_marks_defaults_until_changed
    rule("tracker", "feature", 2)
    RedmineMirror::DefaultMappings.apply(@setting)
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/mirror", params: { mirror_tab: "issue_tracking", mirror_filter: "all" }
    assert_response :success
    assert_select "#mirror-table-tracker tr", text: /Feature.*administrator default/m
    patch "/projects/ecookbook/mirror/settings/modules/issue_tracking", params: { mappings: { tracker: { "2" => "2" } } }
    assert mapping("tracker", 2).from_default
    patch "/projects/ecookbook/mirror/settings/modules/issue_tracking", params: { mappings: { tracker: { "2" => "1" } } }
    assert_equal [1, false], [mapping("tracker", 2).destination_id, mapping("tracker", 2).from_default]
  end

  def test_list_values_take_defaults_per_destination_field
    field = IssueCustomField.create!(name: "Resolution", field_format: "list", possible_values: ["Duplicate", "Not reproducible", "Other"], is_for_all: true,
      trackers: Tracker.all)
    @setting.source_catalog = @setting.source_catalog.merge("custom_field" => { "78" => "Resolution" }, "custom_field_definitions" => {
      "78" => { "field_format" => "list", "multiple" => false, "possible_values" => [
        { "value" => "10 - Duplicate", "label" => "10 - Duplicate" }, { "value" => "20 - Non reproductible", "label" => "20 - Non reproductible" },
        { "value" => "other", "label" => "other" }] } })
    @setting.save!
    rule("custom_field", "resolution", field.id)
    MirrorDefaultMapping.create!(reference_type: "custom_field_value", custom_field: field, source_name: "10 - Duplicate", destination_value: "Duplicate")
    MirrorDefaultMapping.create!(reference_type: "custom_field_value", custom_field: field, source_name: nil, destination_value: "Not reproducible")
    assert_equal 1 + 2, RedmineMirror::DefaultMappings.apply(@setting)
    adapter = RedmineMirror::Adapters::CustomFields.new
    values = @setting.reload.module_options.dig("issue_custom_fields", "value_mappings", "78")
    assert_equal "Duplicate", values[adapter.value_key("10 - Duplicate")]
    assert_equal "Not reproducible", values[adapter.value_key("20 - Non reproductible")]
    # "other" has a local namesake: left to the person.
    assert_nil values[adapter.value_key("other")]
    # A value is never replaced.
    MirrorDefaultMapping.where(source_name: "10 - Duplicate").update_all(destination_value: "Other")
    assert_equal 0, RedmineMirror::DefaultMappings.apply(@setting)
    assert_equal "Duplicate", @setting.reload.module_options.dig("issue_custom_fields", "value_mappings", "78", adapter.value_key("10 - Duplicate"))
  end

  def test_csv_import_checks_every_line_then_saves_and_exports
    field = IssueCustomField.create!(name: "Environment", field_format: "list", possible_values: ["Validation", "Training"], is_for_all: true)
    log_user("admin", "admin")
    bad = "type;source_name;source_url;destination;custom_field\ntracker;Feature;;Feature request;\ntracker;Unknown tracker;;Nowhere;\n"
    post "/admin/mirror/defaults/import", params: { file: Rack::Test::UploadedFile.new(StringIO.new(bad), "text/csv", original_filename: "defaults.csv") }
    assert_match "3: Unknown destination Nowhere", flash[:error]
    assert_equal 0, MirrorDefaultMapping.count
    duplicate = "type,source_name,destination\ntracker,Feature,Bug\ntracker,FEATURE,Bug\n"
    post "/admin/mirror/defaults/import", params: { file: Rack::Test::UploadedFile.new(StringIO.new(duplicate), "text/csv", original_filename: "defaults.csv") }
    assert_match "same type and source name as line 2", flash[:error]
    good = "\uFEFFtype;source_name;source_url;destination;custom_field\n" \
           "tracker;Feature;;Feature request;\nstatus;;;ignore;\nrole;Former reader;#{SOURCE}/;ignore;\n" \
           "user;;;#2;\ncustom_field_value;Recipe;;validation;Environment\n"
    post "/admin/mirror/defaults/import", params: { file: Rack::Test::UploadedFile.new(StringIO.new(good), "text/csv", original_filename: "defaults.csv") }
    assert_equal "5 defaults imported.", flash[:notice], flash[:error]
    assert_equal 2, MirrorDefaultMapping.find_by(reference_type: "tracker").destination_id
    assert_equal SOURCE, MirrorDefaultMapping.find_by(reference_type: "role").source_url
    assert_equal [field.id, "Validation"], MirrorDefaultMapping.where(reference_type: "custom_field_value").pick(:custom_field_id, :destination_value)
    # Importing again replaces the defaults with the same name.
    post "/admin/mirror/defaults/import", params: { file: Rack::Test::UploadedFile.new(StringIO.new("type;source_name;destination\ntracker;feature;Bug\n"), "text/csv", original_filename: "defaults.csv") }
    assert_equal [[1, "feature"]], MirrorDefaultMapping.where(reference_type: "tracker").pluck(:destination_id, :source_name)
    get "/admin/mirror/defaults.csv"
    assert_response :success
    lines = response.body.lines.map(&:chomp)
    assert_equal "type;source_name;source_url;destination;custom_field", lines.first
    assert_includes lines, "tracker;feature;;Bug;"
    assert_includes lines, "user;;;#{User.find(2).name};"
    assert_includes lines, "custom_field_value;Recipe;;Validation;Environment"
  end

  def test_applying_to_configured_projects_reads_no_source
    rule("tracker", "feature", 2)
    log_user("admin", "admin")
    RedmineMirror::Client.stub(:new, ->(*) { raise "no source is read" }) do
      post "/admin/mirror/defaults/apply"
    end
    assert_equal "1 correspondences saved in the projects.", flash[:notice]
    assert_equal 2, mapping("tracker", 2).destination_id
  end
end
