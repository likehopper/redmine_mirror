# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/08_source_queries.rb
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
# Mirror RM4 -> RM5 migration demo, saved queries on the Redmine 4 source: one query per rule of
# the Saved queries module; then shared through Mirror source (Redmine Mirror 1.0.0-beta.31).
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
project = Project.find_by!(identifier: "mirror-demo")
abort "Queries already seeded" if Query.where(project_id: project.id).exists?
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
alice = User.find_by!(login: "mirror-demo-alice")
lot1 = project.versions.find_by!(name: "Lot 1")
sprint2 = ::Sprint.find_by!(project_id: project.id, name: "Sprint 2")
role = Role.find_by!(name: "Mirror demo")

def save!(klass, project, user, name, visibility, filters, columns: nil, sort: nil, group_by: nil, options: {}, roles: [])
  query = klass.new(name: name)
  query.project = project
  query.user = user
  query.visibility = visibility
  query.filters = filters
  query.column_names = columns if columns
  query.sort_criteria = sort if sort
  query.group_by = group_by
  query.options = (query.options || {}).merge(options)
  query.roles = roles
  query.save!(validate: false)
  query
end

f = ->(operator, *values) { { operator: operator, values: values } }
save!(IssueQuery, project, owner, "Anomalies ouvertes du lot 1", Query::VISIBILITY_PUBLIC,
  { "status_id" => f.("o", ""), "tracker_id" => f.("=", "1"), "fixed_version_id" => f.("=", lot1.id.to_s), "assigned_to_id" => f.("=", "me") },
  columns: [:tracker, :status, :subject, :assigned_to, :cf_88], sort: [%w[priority desc], %w[id asc]], group_by: "status")
save!(IssueQuery, project, owner, "Mes demandes en cours (privée)", Query::VISIBILITY_PRIVATE,
  { "status_id" => f.("=", "2"), "assigned_to_id" => f.("=", owner.id.to_s) })
save!(IssueQuery, project, alice, "Requête privée d'Alice (anonymisée)", Query::VISIBILITY_PRIVATE, { "status_id" => f.("o", "") })
save!(IssueQuery, project, owner, "Visible par le rôle Mirror demo", Query::VISIBILITY_ROLES, { "tracker_id" => f.("=", "2") }, roles: [role])
save!(IssueQuery, project, owner, "Sprint 2 (filtre Scrum)", Query::VISIBILITY_PUBLIC, { "sprint_id" => f.("=", sprint2.id.to_s) })
save!(IssueQuery, project, owner, "Sous-projet précis (non traduisible)", Query::VISIBILITY_PUBLIC, { "subproject_id" => f.("=", "1") })
save!(IssueQuery, project, owner, "Demandes avec tag urgent", Query::VISIBILITY_PUBLIC, { "issue_tags" => f.("=", "Urgent") })
save!(TimeEntryQuery, project, owner, "Temps de développement", Query::VISIBILITY_PUBLIC,
  { "activity_id" => f.("=", "9"), "issue.tracker_id" => f.("=", "1"), "spent_on" => f.("m", "") })
save!(AgileQuery, project, owner, "Tableau kanban de la démo", Query::VISIBILITY_PUBLIC, { "tracker_id" => f.("=", "1", "2", "3") },
  columns: [:id, :priority, :assigned_to],
  options: { f_status: %w[1 2 3], wp: { "2" => "3" }, color_base: "tracker", sprints_enabled: 0, sprint_id: nil, is_default: false, draw_relations: nil })

setting = project.mirror_source_setting
setting.update!(shared_modules: (setting.shared_modules + %w[queries]).uniq)
puts "Queries ready: #{Query.where(project_id: project.id).group(:type).count.inspect}; shared: #{setting.reload.shared_modules.inspect}"
