# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_subprojects_test.rb
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
# Verify that source subprojects are configured from their parent's Mirror settings.

require_relative "../test_helper"

class MirrorSubprojectsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers,
    :projects_trackers, :issue_statuses, :enumerations, :versions, :issue_categories, :custom_fields, :workflows

  SOURCE_SUBPROJECTS = [
    { "id" => 101, "identifier" => "web-shop", "name" => "Web shop", "parent_id" => 12, "modules" => %w[issue_tracking mirror_source] },
    { "id" => 102, "identifier" => "web-app", "name" => "Web app", "parent_id" => 101, "modules" => %w[issue_tracking mirror_source] },
    { "id" => 103, "identifier" => "subproject1", "name" => "Legacy one", "parent_id" => 12, "modules" => %w[issue_tracking mirror_source] }
  ].freeze

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking]
    @setting.api_key = "parent-api-key"
    @setting.source_catalog = { "tracker" => { "1" => "Bug" }, "subprojects" => SOURCE_SUBPROJECTS }
    @setting.catalog_status = "ready"
    @setting.save!
  end

  def configure(rows)
    post "/projects/ecookbook/mirror/settings/subprojects", params: { subprojects: rows }
    assert_redirected_to "/projects/ecookbook/settings/mirror#mirror-subprojects"
  end

  # Created with the chosen names, or linked to an existing subproject, in tree order; each
  # gets Mirror, the modules it needs and a configuration taken from the parent's.
  def test_creates_and_links_subprojects_from_the_parent_settings
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/mirror"
    assert_select "#mirror-subprojects-form tr#mirror-subproject-102 td[style='padding-left: 2em']", text: /Web app/
    # A local subproject with the source identifier is proposed.
    assert_select "#mirror-subproject-103-target option[selected][value='3']"
    configure("101" => { include: "1", target: "new", name: "Boutique web", identifier: "boutique-web", modules: ["issue_tracking"] },
      "102" => { include: "1", target: "new", name: "Appli", identifier: "boutique-app", modules: ["issue_tracking"] },
      "103" => { include: "1", target: "3", modules: ["issue_tracking"] })
    assert_nil flash[:error]
    shop = Project.find_by!(identifier: "boutique-web")
    app = Project.find_by!(identifier: "boutique-app")
    assert_equal [@project, shop], [shop.parent, app.parent]
    assert_equal "Boutique web", shop.name
    # Redmine's project tree bounds stay consistent.
    assert_equal [shop, app, Project.find(3)].map(&:id).sort, (Project.find(1).descendants.pluck(:id) & [shop, app, Project.find(3)].map(&:id)).sort
    assert_includes Project.find(shop.id).descendants, app
    [shop, app, Project.find(3)].zip([101, 102, 103]).each do |project, source_id|
      assert project.module_enabled?(:mirror) && project.module_enabled?(:issue_tracking)
      child = project.mirror_project_setting
      assert_equal [@setting.id, source_id, "pending", "parent-api-key"], [child.parent_setting_id, child.source_project_id, child.catalog_status, child.api_key]
    end
    get "/projects/ecookbook/settings/mirror"
    assert_select "tr#mirror-subproject-101 a", text: "Boutique web"
    assert_select "#mirror-subproject-101-include", count: 0
    # Configured subprojects say where they come from and list no subprojects of their own.
    get "/projects/boutique-web/settings/mirror"
    assert_select "#mirror-subprojects-from-parent a", text: @project.name
    assert_select "#mirror-subprojects-form", count: 0
  end

  # A new parent's key reaches its subprojects; a row whose source parent is left out, or
  # that the person may not create, is refused without stopping the others.
  def test_refused_rows_and_key_change
    log_user("admin", "admin")
    configure("102" => { include: "1", target: "new", name: "Appli", identifier: "boutique-app", modules: ["issue_tracking"] },
      "103" => { include: "1", target: "3", modules: ["issue_tracking"] })
    assert_match(/Web app: its source parent is not configured here/, flash[:error])
    assert_nil Project.find_by(identifier: "boutique-app")
    child = Project.find(3).mirror_project_setting
    patch "/projects/ecookbook/mirror/settings/connection", params: { connection: { source_url: @setting.source_url, source_project_id: "12",
      api_key: "new-parent-key", modules: ["issue_tracking"] } }
    assert_equal "new-parent-key", child.reload.api_key
  end

  def test_creating_needs_the_add_subprojects_permission
    Role.find(2).add_permission!(:manage_mirror)
    Role.find(2).remove_permission!(:add_subprojects)
    log_user("dlopper", "foo")
    configure("101" => { include: "1", target: "new", name: "Boutique web", identifier: "boutique-web", modules: ["issue_tracking"] })
    assert_match(/Add subprojects permission/, flash[:error])
    assert_nil Project.find_by(identifier: "boutique-web")
  end

  # The subproject takes the parent's correspondences it has none for; its own stay.
  def test_subproject_takes_the_parent_correspondences_it_lacks
    @setting.update!(source_catalog: @setting.source_catalog.merge("tracker" => { "1" => "Bug", "2" => "Feature" }))
    @project.mirror_reference_mappings.create!(reference_type: "tracker", source_id: 1, mode: "existing", destination_id: 1)
    @project.mirror_reference_mappings.create!(reference_type: "tracker", source_id: 2, mode: "existing", destination_id: 2)
    child_project = Project.find(3)
    child_project.enable_module!(:mirror)
    child = MirrorProjectSetting.new(project: child_project, parent_setting: @setting, source_url: @setting.source_url, source_project_id: 103)
    child.selected_modules = %w[issue_tracking]
    child[:encrypted_api_key] = @setting[:encrypted_api_key]
    child.source_catalog = { "tracker" => { "1" => "Bug", "2" => "Feature" } }
    child.save!
    child_project.mirror_reference_mappings.create!(reference_type: "tracker", source_id: 2, mode: "existing", destination_id: 3)
    assert_equal 1, RedmineMirror::ParentMappings.apply(child.reload)
    assert_equal({ 1 => 1, 2 => 3 }, child_project.mirror_reference_mappings.where(reference_type: "tracker").pluck(:source_id, :destination_id).to_h)
  end

  # A parent's successful run queues its subprojects' runs, the same way.
  def test_parent_run_queues_its_subprojects
    log_user("admin", "admin")
    configure("103" => { include: "1", target: "3", modules: ["issue_tracking"] })
    run = @project.mirror_sync_runs.create!(apply: true, trigger: "manual", status: "succeeded", requested_by: User.find(1))
    RedmineMirror::Synchronization.queue_subprojects(@setting, run)
    queued = Project.find(3).mirror_sync_runs.sole
    assert_equal [true, "parent", "queued", 1], [queued.apply?, queued.trigger, queued.status, queued.requested_by_id]
    failed = @project.mirror_sync_runs.create!(apply: true, trigger: "manual", status: "failed")
    RedmineMirror::Synchronization.queue_subprojects(@setting, failed)
    assert_equal 1, Project.find(3).mirror_sync_runs.count
  end
end
