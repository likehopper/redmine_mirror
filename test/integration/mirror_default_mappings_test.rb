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
    # One tab per table, and the forms on their own page.
    assert_select "#tab-tracker"
    assert_select "#tab-custom_field_value"
    assert_select "form.mirror-default-form", count: 0
    get "/admin/mirror/defaults/new", params: { type: "tracker" }
    assert_response :success
    assert_select "#mirror-default-form-tracker textarea"
    get "/admin/mirror/defaults/new", params: { type: "custom_field" }
    assert_select "#mirror-default-destination option[value=priority]", text: "Priority (standard field)"
    # Users only take a fallback.
    get "/admin/mirror/defaults/new", params: { type: "user" }
    assert_select "#mirror-default-form-user textarea", count: 0
    get "/admin/mirror/defaults/new", params: { type: "unknown" }
    assert_response 404
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "tracker", source_names: "Feature\nEnhancement\nfeature", destination: "2" } }
    assert_redirected_to "/admin/mirror/defaults?tab=tracker"
    assert_equal [["Enhancement", 2], ["Feature", 2]], MirrorDefaultMapping.where(reference_type: "tracker").order(:source_key).pluck(:source_name, :destination_id)
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "status", source_names: "", destination: "ignore" } }
    assert MirrorDefaultMapping.find_by(reference_type: "status", source_key: nil, mode: "ignore")
    # Priorities cannot be ignored; an unknown destination is refused.
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "priority", source_names: "Low priority", destination: "ignore" } }
    assert flash[:error]
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "tracker", source_names: "Unknown tracker", destination: "999" } }
    assert flash[:error]
    assert_redirected_to "/admin/mirror/defaults/new?type=tracker"
    # The same name and source again is refused.
    post "/admin/mirror/defaults", params: { default_mapping: { reference_type: "tracker", source_names: "FEATURE", destination: "1" } }
    assert flash[:error]
    get "/admin/mirror/defaults", params: { tab: "tracker" }
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
    rule("status", "Unused status", 3)
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
    # Defaults, including explicit ones, leave references the project does not use.
    assert_nil mapping("status", 9)
    # A saved correspondence is never changed.
    assert_equal [6, false], [mapping("priority", 4).destination_id, mapping("priority", 4).from_default]
    assert_equal 10, mapping("activity", 5).destination_id
    # A generic account need not be a project member.
    refute @project.users.include?(User.find(4))
    assert_equal 4, mapping("user", 70).destination_id
  end

  def test_localizable_aliases_match_both_sides_without_changing_their_names
    catalog = @setting.source_catalog
    catalog["reference_aliases"] = { "tracker" => { "2" => ["Feature", "Fonction - Exigence"] } }
    @setting.update!(source_catalog: catalog)
    settings = { "locales" => { "tracker" => { "2" => { "fr" => "Exigence" } } } }
    RedmineMirror::LocalizedNames.stub(:localizable_settings, settings) do
      result = RedmineMirror::DefaultMappings.import(
        "type;source_name;destination\ntracker;Fonction - Exigence;Exigence\n")
      assert_equal [1, []], [result.saved, result.errors]
      # The explicit tracker rule and the built-in departed-user fallback are saved.
      assert_equal 2, RedmineMirror::DefaultMappings.apply(@setting)
    end
    assert_equal [2, true], [mapping("tracker", 2).destination_id, mapping("tracker", 2).from_default]
  end

  def test_custom_field_default_can_feed_the_standard_priority
    catalog = @setting.source_catalog.merge("custom_field" => { "900" => "Sévérité" }, "custom_field_definitions" => {
      "900" => { "field_format" => "list", "multiple" => false, "possible_values" => [{ "value" => "Blocking", "label" => "Blocking" }] } })
    @setting.update!(source_catalog: catalog)
    result = RedmineMirror::DefaultMappings.import("type;source_name;destination\ncustom_field;Severity;priority\n")
    assert_equal 1, result.saved
    @setting.update!(source_catalog: catalog.merge("reference_aliases" => { "custom_field" => { "900" => ["Sévérité", "Severity"] } }))

    # The explicit field rule and the built-in departed-user fallback are saved.
    assert_equal 2, RedmineMirror::DefaultMappings.apply(@setting)
    assert_equal ["priority", nil, true], [mapping("custom_field", 900).mode, mapping("custom_field", 900).destination_id,
      mapping("custom_field", 900).from_default]
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
    # One field, two values, and the built-in anonymization of the departed user.
    assert_equal 1 + 2 + 1, RedmineMirror::DefaultMappings.apply(@setting)
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
    get "/admin/mirror/defaults/import"
    assert_response :success
    post "/admin/mirror/defaults/import", params: { file: Rack::Test::UploadedFile.new(StringIO.new(bad), "text/csv", original_filename: "defaults.csv") }
    assert_response 422
    assert_select "#mirror-defaults-import-errors tbody tr", count: 1
    assert_select "#mirror-defaults-import-errors td", text: "Unknown destination Nowhere"
    assert_select "#mirror-defaults-rejected[download]"
    assert_equal 0, MirrorDefaultMapping.count
    duplicate = "type,source_name,destination\ntracker,Feature,Bug\ntracker,FEATURE,Bug\n"
    post "/admin/mirror/defaults/import", params: { file: Rack::Test::UploadedFile.new(StringIO.new(duplicate), "text/csv", original_filename: "defaults.csv") }
    assert_select "#mirror-defaults-import-errors td", text: "same type and source name as line 2"
    # Skipping the errors saves the valid lines.
    post "/admin/mirror/defaults/import", params: { skip_errors: "1", file: Rack::Test::UploadedFile.new(StringIO.new(bad), "text/csv", original_filename: "defaults.csv") }
    assert_response :success
    assert_select ".flash.notice", text: "1 defaults imported, 1 lines skipped."
    assert_equal [2], MirrorDefaultMapping.pluck(:destination_id)
    MirrorDefaultMapping.delete_all
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
    assert_equal "2 correspondences saved in the projects.", flash[:notice]
    assert_equal 2, mapping("tracker", 2).destination_id
    assert_equal "anonymous", mapping("user", 70).mode
  end
  def test_rejected_lines_come_back_as_csv_with_their_error
    text = "type;source_name;source_url;destination;custom_field\ntracker;Feature;;Bug;\nstatus;Done;;Nowhere;\nmood;Happy;;Bug;\n"
    result = RedmineMirror::DefaultMappings.import(text)
    assert_equal 0, result.saved
    assert_equal ["3: Unknown destination Nowhere", "4: Unknown type mood"], result.messages
    rows = CSV.parse(result.rejected_csv, col_sep: ";")
    assert_equal %w[type source_name source_url destination custom_field error], rows.first
    assert_equal ["status", "Done", "", "Nowhere", "", "Unknown destination Nowhere"], rows.second
    assert_equal 0, MirrorDefaultMapping.count
    assert_equal 1, RedmineMirror::DefaultMappings.import(text, partial: true).saved
  end

  def test_a_project_can_refuse_the_defaults
    rule("tracker", "feature", 2)
    log_user("admin", "admin")
    get "/projects/ecookbook/settings", params: { tab: "mirror" }
    assert_select "#mirror-use-default-mappings[checked]"
    patch "/projects/ecookbook/mirror/settings/defaults", params: { use_default_mappings: "0" }
    refute @setting.reload.use_default_mappings
    refute RedmineMirror::DefaultMappings.automatic?(@setting)
    # Neither the administrator's button nor a reading of the source fills it.
    post "/admin/mirror/defaults/apply"
    assert_equal "0 correspondences saved in the projects.", flash[:notice]
    assert_nil mapping("tracker", 2)
    # The project's own button still applies them.
    post "/projects/ecookbook/mirror/settings/defaults/apply"
    assert_equal "2 correspondences saved from the defaults.", flash[:notice]
    assert_equal [2, true], [mapping("tracker", 2).destination_id, mapping("tracker", 2).from_default]
  end

  def test_reset_replaces_only_the_references_whose_name_has_a_default
    rule("tracker", "feature", 2)
    rule("tracker", nil, 3)
    @project.mirror_reference_mappings.create!(reference_type: "tracker", source_id: 2, destination_id: 1)
    @project.mirror_reference_mappings.create!(reference_type: "tracker", source_id: 3, destination_id: 1)
    log_user("admin", "admin")
    @project.mirror_reference_mappings.create!(reference_type: "user", source_id: 70, mode: "anonymous")
    post "/projects/ecookbook/mirror/settings/defaults/apply"
    assert_equal "0 correspondences saved from the defaults.", flash[:notice]
    assert_equal 1, mapping("tracker", 2).destination_id
    post "/projects/ecookbook/mirror/settings/defaults/apply", params: { reset: "1" }
    assert_equal [2, true], [mapping("tracker", 2).destination_id, mapping("tracker", 2).from_default]
    # The fallback never replaces a correspondence.
    assert_equal [1, false], [mapping("tracker", 3).destination_id, mapping("tracker", 3).from_default]
  end

  def test_only_managers_apply_the_defaults_of_a_project
    rule("tracker", "feature", 2)
    log_user("dlopper", "foo")
    post "/projects/ecookbook/mirror/settings/defaults/apply"
    assert_response 403
    assert_nil mapping("tracker", 2)
  end
  def test_users_without_fallback_are_anonymized_unless_an_account_matches
    catalog = @setting.source_catalog
    catalog["user"] = catalog["user"].merge("71" => "Robert Hill", "72" => "Someone Else")
    catalog["user_used"] = %w[70 71 72]
    # 72 shares the email of a local account: the form proposes it.
    catalog["user_details"] = { "72" => { "mail" => User.find(3).mail.upcase } }
    @setting.update!(source_catalog: catalog)
    RedmineMirror::DefaultMappings.apply(@setting)
    assert_equal "anonymous", mapping("user", 70).mode
    # "Robert Hill" is a local namesake.
    assert_nil mapping("user", 71)
    assert_nil mapping("user", 72)
    # An administrator's fallback replaces the built-in one.
    @project.mirror_reference_mappings.where(reference_type: "user").delete_all
    rule("user", nil, 4)
    RedmineMirror::DefaultMappings.apply(@setting)
    assert_equal [4, "existing"], [mapping("user", 70).destination_id, mapping("user", 70).mode]
  end

  def test_administrator_sets_the_default_account_for_anonymized_time
    log_user("admin", "admin")
    get "/admin/mirror/defaults", params: { tab: "user" }
    assert_select "#mirror-default-user-built-in"
    patch "/admin/mirror/defaults/anonymous_time_user", params: { anonymous_time_user_id: "2" }
    assert_redirected_to "/admin/mirror/defaults?tab=user"
    assert_equal 2, RedmineMirror.default_anonymous_time_user_id
    users = RedmineMirror::Adapters::Users.new
    assert_equal 2, users.resolve({ "user" => { "70" => "anonymous" } }, 70, required: true)
    # The project's own account wins.
    assert_equal 3, users.resolve({ "user" => { "70" => "anonymous" } }, 70, required: true, options: { "anonymous_user_id" => 3 })
    # The default account must be a member of the project.
    entries = RedmineMirror::Adapters::TimeEntries.new
    record = { "hours" => 1, "spent_on" => "2026-11-01", "activity" => { "id" => 5 }, "user" => { "id" => 70 } }
    mappings = { "user" => { "70" => "anonymous" }, "activity" => { "5" => "9" } }
    assert_equal 2, entries.payload(record, 1, mappings, ->(*) {})["user_id"]
    elsewhere = Project.create!(name: "Without the account", identifier: "without-the-account")
    error = assert_raises(RedmineMirror::Error) { entries.payload(record, elsewhere.id, mappings, ->(*) {}) }
    assert_match "not an active member", error.message
    patch "/admin/mirror/defaults/anonymous_time_user", params: { anonymous_time_user_id: "" }
    assert_nil RedmineMirror.default_anonymous_time_user_id
    error = assert_raises(RedmineMirror::Error) { users.resolve({ "user" => { "70" => "anonymous" } }, 70, required: true) }
    assert_match "not imported", error.message
  end
end
