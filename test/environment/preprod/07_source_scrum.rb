# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/07_source_scrum.rb
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
# Mirror RM4 -> RM5 migration demo, Scrum on the Redmine 4 source: sprints of every status, two
# product backlogs without dates, a duplicate name, a sprint shared from another project,
# positions and story points (0.5 included); then shared through Mirror source
# (Redmine Mirror 1.0.0-beta.30). Written with update_columns: no journal, no callback.
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
abort "Scrum plugin missing" unless defined?(::Sprint) && Issue.column_names.include?("sprint_id")

project = Project.find_by!(identifier: "mirror-demo")
external = Project.find_by!(identifier: "mirror-demo-externe")
abort "Scrum already seeded" if ::Sprint.where(project_id: project.id).exists?
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
[project, external].each { |row| row.enable_module!(:scrum) }
Role.find_by!(name: "Mirror reader").add_permission!(:view_sprint_board)
Role.find_by!(name: "Mirror demo").add_permission!(:view_sprint_board, :view_product_backlog, :manage_sprints)

def sprint!(project, user, name, status, start_date, end_date, backlog: false, shared: false, description: "")
  sprint = ::Sprint.new(name: name, description: description, sprint_start_date: start_date, sprint_end_date: end_date,
    status: status, is_product_backlog: backlog, shared: shared)
  sprint.project = project
  sprint.user = user
  sprint.save!(validate: false)
  sprint
end

closed = sprint!(project, owner, "Sprint 1", "closed", Date.new(2026, 9, 1), Date.new(2026, 9, 14), description: "Sprint fermé avec une demande encore ouverte")
locked = sprint!(project, owner, "Sprint 2", "locked", Date.new(2026, 9, 15), Date.new(2026, 9, 28), shared: true)
open = sprint!(project, owner, "Sprint 3", "open", Date.new(2026, 9, 29), Date.new(2026, 10, 12))
duplicate = sprint!(project, owner, "Sprint 1", "open", Date.new(2026, 10, 13), Date.new(2026, 10, 26), description: "Même nom que le sprint 1 (donnée historique)")
backlog = sprint!(project, owner, "Product backlog", "open", nil, nil, backlog: true)
technical = sprint!(project, owner, "Backlog technique", "open", nil, nil, backlog: true)
shared = sprint!(external, owner, "Sprint partagé", "open", Date.new(2026, 10, 1), Date.new(2026, 10, 31), shared: true)

story_points = CustomField.find_by(id: (Scrum::Setting.story_points_custom_field_id rescue nil))
issues = project.issues.order(:id).to_a
plan = [[closed, "3"], [closed, "5"], [locked, "0.5"], [locked, "8"], [open, "2"], [duplicate, "1"],
        [backlog, "13"], [backlog, nil], [technical, "0.5"], [shared, "3"]]
issues.each_with_index do |issue, index|
  sprint, points = plan[index] || [backlog, nil]
  issue.update_columns(sprint_id: sprint.id, position: index + 1)
  next unless story_points && points
  value = CustomValue.find_or_initialize_by(customized_type: "Issue", customized_id: issue.id, custom_field_id: story_points.id)
  value.value = points
  value.save!(validate: false)
end
# The closed sprint keeps an open issue, as 281 production sprints do.
open_in_closed = Issue.where(sprint_id: closed.id).joins(:status).where(issue_statuses: { is_closed: false }).count

setting = project.mirror_source_setting
setting.update!(shared_modules: (setting.shared_modules + %w[scrum]).uniq)
puts "Scrum ready: #{::Sprint.where(project_id: [project.id, external.id]).count} sprints, #{Issue.where(project_id: project.id).where.not(sprint_id: nil).count} issues in a sprint, " \
  "open issues in the closed sprint: #{open_in_closed}, story points field: #{story_points&.name.inspect}; shared: #{setting.reload.shared_modules.inspect}"
