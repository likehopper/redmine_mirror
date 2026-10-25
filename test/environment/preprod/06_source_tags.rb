# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/06_source_tags.rb
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
# Mirror RM4 -> RM5 migration demo, tags on the Redmine 4 source: tags set through the history
# (journal details), accents, spaces, case, a removed tag, a private issue; then shared
# through Mirror source (Redmine Mirror 1.0.0-beta.28). Runs once.
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
abort "Redmine Tags plugin missing" unless Issue.method_defined?(:tag_list)

ActionMailer::Base.perform_deliveries = false
Mailer.singleton_class.instance_methods(false).grep(/\Adeliver_/).each { |name| Mailer.define_singleton_method(name) { |*| } }
MattermostDeliverJob.define_singleton_method(:perform_later) { |*| } if defined?(MattermostDeliverJob)

project = Project.find_by!(identifier: "mirror-demo")
issues = project.issues.order(:id).to_a
abort "Tags already seeded" if issues.any? { |issue| issue.tag_list.any? }
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
alice = User.find_by!(login: "mirror-demo-alice")

def tag!(issue, user, tags, note)
  issue.reload.init_journal(user, note)
  issue.tag_list = tags
  issue.save!
end

plan = {
  0 => [%w[urgent client], ["urgent", "client", "à valider"]],
  1 => [["export PDF", "Lot 1"], nil],
  2 => [%w[mentions-légales], nil],
  3 => [%w[UTF-8 accents], nil],
  4 => [["Nos offres", "front"], ["front"]],
  6 => [%w[recette], nil]
}
plan.each do |index, (first, second)|
  issue = issues[index]
  next unless issue
  tag!(issue, owner, first, "Ajout de tags.")
  tag!(issue, alice, second, "Mise à jour des tags.") if second
end
# Case and private issue: the same tag written differently, on the private issue too.
private_issue = issues.find(&:is_private?)
tag!(private_issue, alice, %w[URGENT confidentiel], "Tags sur une demande privée.") if private_issue
images = issues.find { |issue| issue.subject.start_with?("[Cas] Images") }
tag!(images, owner, %w[images pièces-jointes], "Tags de la demande des images.") if images

project.mirror_source_setting.update!(shared_modules: (project.mirror_source_setting.shared_modules + %w[issue_tags]).uniq)
tagged = issues.map(&:reload).select { |issue| issue.tag_list.any? }
puts "Tags ready: #{tagged.size} tagged issues, tags #{tagged.flat_map { |issue| issue.tag_list.to_a }.uniq.sort.inspect}, " \
  "journal details: #{JournalDetail.joins(:journal).where(journals: { journalized_type: 'Issue', journalized_id: issues.map(&:id) }, prop_key: 'tag_list').count}; " \
  "shared: #{project.mirror_source_setting.reload.shared_modules.inspect}"
