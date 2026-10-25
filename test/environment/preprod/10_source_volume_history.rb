# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/10_source_volume_history.rb
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
# Mirror RM4 -> RM5 migration demo, volume batch history on the Redmine 4 source. With the Scrum
# module on, Redmine 4 merged the successive journals of the volume seed into one per
# issue: this adds the missing journals directly (notes, private notes, status and
# assignee details, original dates and authors), as an old history holds them. Runs once.
# Ruby 2.6 (Redmine 4).
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
RNG = Random.new(43)
LOREM = ["Lorem ipsum dolor sit amet, consectetur adipiscing elit.", "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
  "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.", "Duis aute irure dolor in reprehenderit in voluptate velit esse."].freeze
project = Project.find_by!(identifier: "mirror-demo")
people = [ENV.fetch("MIRROR_DEMO_OWNER"), "mirror-demo-alice", "mirror-demo-bob"].map { |login| User.find_by!(login: login) }
volume = project.issues.where("subject LIKE ?", "[Volume] Demande%").order(:id).to_a
abort "History already completed" if Journal.where(journalized_type: "Issue", journalized_id: volume.map(&:id)).count > volume.size * 2

def add_journal(issue, user, notes, at, private_notes: false, details: [])
  journal = Journal.new(journalized: issue, user: user, notes: notes, private_notes: private_notes)
  details.each { |prop_key, old_value, new_value| journal.details << JournalDetail.new(property: "attr", prop_key: prop_key, old_value: old_value, value: new_value) }
  journal.save!(validate: false)
  journal.update_columns(created_on: at)
  journal
end

added = 0
status_cycle = [1, 2, 4, 2, 3]
volume.each_with_index do |issue, n|
  at = issue.created_on + 2.days
  previous = 1
  (n % 6).times do |step|
    details = []
    if step.odd?
      status = status_cycle[(n + step) % status_cycle.size]
      details << ["status_id", previous.to_s, status.to_s] unless status == previous
      previous = status
    end
    details << ["assigned_to_id", nil, people[step % 2].id.to_s] if step == 2
    notes = step.even? || details.empty? ? "#{LOREM[RNG.rand(LOREM.size)]} (étape #{step + 1})" : ""
    add_journal(issue, people[(n + step) % 3], notes, at + step.days, private_notes: (n + step) % 13 == 0, details: details)
    added += 1
  end
end
cent = project.issues.find_by!("subject LIKE ?", "[Volume] Cas cent%")
(cent.journals.count...100).each do |k|
  add_journal(cent, people[k % 3], "Note #{k + 1} : #{LOREM[k % LOREM.size]}", Time.utc(2026, 1, 1, 9) + k.hours)
  added += 1
end
puts "journals added: #{added}; volume issues journals: #{Journal.where(journalized_type: 'Issue', journalized_id: volume.map(&:id)).count}; " \
  "cent notes: #{cent.journals.count}; project journals: #{Journal.where(journalized_type: 'Issue', journalized_id: project.issues.select(:id)).count}"
