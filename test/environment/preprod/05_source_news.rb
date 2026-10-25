# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/05_source_news.rb
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
# Mirror RM4 -> RM5 migration demo, news on the Redmine 4 source: News module, news with Textile,
# inline images, files, comments (one by the locked author), past dates. Runs once.
# Sharing News through Mirror source needs Redmine Mirror 1.0.0-beta.26 on this Redmine.
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
ASSETS = "/tmp/mirror-demo-assets"

ActionMailer::Base.perform_deliveries = false
Mailer.singleton_class.instance_methods(false).grep(/\Adeliver_/).each { |name| Mailer.define_singleton_method(name) { |*| } }
MattermostDeliverJob.define_singleton_method(:perform_later) { |*| } if defined?(MattermostDeliverJob)

LOREM = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " \
  "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat."

def attach(container, author, file, name: nil)
  name ||= file
  attachment = Attachment.new(container: container, author: author, description: "Fichier de l'annonce")
  attachment.file = File.open(File.join(ASSETS, file), "rb")
  attachment.filename = name
  attachment.content_type = Redmine::MimeType.of(name) || "application/octet-stream"
  attachment.save!
  attachment
end

project = Project.find_by!(identifier: "mirror-demo")
abort "News already seeded" if project.news.exists?
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
alice = User.find_by!(login: "mirror-demo-alice")
bob = User.find_by!(login: "mirror-demo-bob")
User.current = owner
project.enable_module!(:news)
role = Role.find_by!(name: "Mirror demo")
role.add_permission!(:manage_news, :comment_news) unless role.has_permission?(:manage_news)
first_issue = project.issues.order(:id).first

items = [
  [owner, Time.utc(2019, 6, 3, 8), "Lancement du projet", "Le projet de démonstration démarre",
    "h2. Lancement\n\nLe projet démarre aujourd'hui. Voir le schéma :\n\n!schema-architecture.png!\n\n#{LOREM}\n\n* Lot 1 : socle\n* Lot 2 : export PDF\n\nSuivi dans ##{first_issue.id}.",
    [["schema-architecture.png"], ["specification-fonctionnelle.pdf"]],
    [[alice, Time.utc(2019, 6, 3, 9, 30), "Bravo à toute l'équipe !"], [bob, Time.utc(2019, 6, 4, 10), "Je serai le référent technique. #{LOREM}"]]],
  [alice, Time.utc(2026, 9, 15, 17), "Comité de pilotage du 15/09", "",
    "Compte rendu disponible dans les documents.\n\n|_. Décision |_. Échéance |\n| Lot 1 en recette | 15/12/2026 |\n\n!>capture-ecran.jpg!\n\n#{LOREM}",
    [["capture-ecran.jpg"], ["compte-rendu réunion.docx"]], [[owner, Time.utc(2026, 9, 16, 8), "Merci pour le compte rendu."]]],
  [owner, Time.utc(2026, 10, 1, 9), "Mise en production du lot 0", "Version « Lot 0 (fermée) » livrée",
    "La version *Lot 0* est livrée. Les accents é è à ç œ € passent.\n\nbc. git tag lot-0", [], []],
  [bob, Time.utc(2025, 1, 10, 14), "Annonce d'un auteur parti", "Écrite par un compte verrouillé depuis",
    "#{LOREM}\n\n#{LOREM}", [["Devis client (v2) 2026.pdf"]], [[alice, Time.utc(2025, 1, 11, 9), "Noté, merci Bob."]]]
]
items.each do |author, created_on, title, summary, description, files, comments|
  news = News.new(project: project, author: author, title: title, summary: summary, description: description)
  news.save!
  news.update_columns(created_on: created_on)
  files.each { |file, name| attach(news, author, file, name: name).update_columns(created_on: created_on + 60) }
  comments.each do |comment_author, at, text|
    comment = Comment.new(commented: news, author: comment_author, comments: text)
    comment.save!
    comment.update_columns(created_on: at, updated_on: at)
  end
end

# Share News when this Redmine runs Mirror 1.0.0-beta.26 or later.
setting = project.mirror_source_setting
if RedmineMirror::Source::KINDS.include?("news")
  setting.update!(shared_modules: (setting.shared_modules + %w[news]).uniq)
end
missing = Attachment.where(container: project.news).reject { |row| File.exist?(row.diskfile) }
puts "News ready: #{project.news.count} news, #{Comment.where(commented: project.news).count} comments, " \
  "#{Attachment.where(container: project.news).count} files (missing: #{missing.size}); shared: #{setting.reload.shared_modules.inspect}"
