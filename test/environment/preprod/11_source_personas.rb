# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/11_source_personas.rb
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
# Mirror RM4 -> RM5 migration demo, personas on the Redmine 4 source: Alice is the client (her time
# goes to Tom, most of her development issues too), Bob the former developer (locked),
# Tom a second developer and Pierre the pilot, each with notes, time and other data.
# Direct writes (no issue save): Redmine 4 with Scrum merges journals of one run. Runs once.
# Ruby 2.6 (Redmine 4).
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
ActionMailer::Base.perform_deliveries = false
Mailer.singleton_class.instance_methods(false).grep(/\Adeliver_/).each { |name| Mailer.define_singleton_method(name) { |*| } }
MattermostDeliverJob.define_singleton_method(:perform_later) { |*| } if defined?(MattermostDeliverJob)

project = Project.find_by!(identifier: "mirror-demo")
abort "Personas already there" if User.exists?(login: "mirror-demo-tom")
role = Role.find_by!(name: "Mirror demo")
alice = User.find_by!(login: "mirror-demo-alice")
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))

def person(login, firstname, lastname)
  user = User.new(firstname: firstname, lastname: lastname, mail: "#{login}@example.invalid", language: "fr")
  user.login = login
  user.password = user.password_confirmation = "#{SecureRandom.base64(24)}aA1!"
  user.save!
  user
end
tom = person("mirror-demo-tom", "Tom", "Développeur")
pierre = person("mirror-demo-pilote", "Pierre", "Pilote")
[tom, pierre].each { |user| Member.create!(project: project, user_id: user.id, roles: [role]) }

def note(issue, user, text, at)
  journal = Journal.new(journalized: issue, user: user, notes: text)
  journal.save!(validate: false)
  journal.update_columns(created_on: at)
end

# Alice is the client: her time goes to Tom, and her development issues except ten.
moved_time = TimeEntry.where(project_id: project.id, user_id: alice.id).update_all(user_id: tom.id)
alice_issues = project.issues.where(assigned_to_id: alice.id).order(:id).to_a
alice_issues.drop(10).each { |issue| issue.update_columns(assigned_to_id: tom.id) }

volume = project.issues.where("subject LIKE ?", "[Volume] Demande%").order(:id).to_a
# Tom: notes and time on development issues.
volume.each_with_index do |issue, n|
  next unless n % 4 == 1
  note(issue, tom, "Correctif en cours, livraison prévue sur la branche feature-#{issue.id}.", issue.created_on + 3.days)
  entry = TimeEntry.new(project: project, issue: issue, user: tom, activity_id: 9, spent_on: issue.created_on.to_date + 3, hours: [1, 2, 3.5, 6][n % 4], comments: "Développement")
  entry.save!(validate: false)
end
# Pierre: steering notes, project time, news, queries, watches.
volume.each_with_index do |issue, n|
  next unless n % 10 == 0
  note(issue, pierre, "Point de pilotage : priorité confirmée avec le client.", issue.created_on + 4.days)
  issue.add_watcher(pierre)
end
30.times do |k|
  entry = TimeEntry.new(project: project, user: pierre, activity_id: 20, spent_on: Date.new(2025, 2, 3) + k * 14, hours: 1.5, comments: "Comité de pilotage #{k + 1}")
  entry.save!(validate: false)
end
2.times do |k|
  news = News.new(project: project, author: pierre, title: "Pilotage : point mensuel #{k + 1}", summary: "Avancement et risques", description: "Avancement du lot #{k + 1}, risques et décisions.")
  news.save!
  news.update_columns(created_on: Time.utc(2026, 5 + k, 1, 9))
end
[[Query::VISIBILITY_PUBLIC, "Pilotage : demandes urgentes"], [Query::VISIBILITY_PRIVATE, "Pilotage : mes points (privée)"]].each do |visibility, name|
  query = IssueQuery.new(name: name)
  query.project = project
  query.user = pierre
  query.visibility = visibility
  query.filters = { "priority_id" => { operator: "=", values: ["6"] }, "status_id" => { operator: "o", values: [""] } }
  query.save!(validate: false)
end

puts "Personas ready: Tom and Pierre members; time moved from Alice to Tom: #{moved_time}; issues moved to Tom: #{[alice_issues.size - 10, 0].max}; " \
  "time by user: #{TimeEntry.where(project_id: project.id).group(:user_id).count.map { |id, n| [User.find(id).login, n] }.inspect}"
