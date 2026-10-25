# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/01_source_seed.rb
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
# Mirror RM4 -> RM5 migration demo on the Redmine 4 preprod (Redmine 4).
# Touches only the "mirror-demo" project, its own role and its own accounts.
# Idempotent: each section is skipped when its data already exists.
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4

# No mail and no Mattermost post from this run (this process only).
ActionMailer::Base.perform_deliveries = false
Mailer.singleton_class.instance_methods(false).grep(/\Adeliver_/).each { |name| Mailer.define_singleton_method(name) { |*| } }
MattermostDeliverJob.define_singleton_method(:perform_later) { |*| } if defined?(MattermostDeliverJob)

def fill_required(record)
  record.available_custom_fields.select(&:is_required?).each do |field|
    next if record.custom_field_value(field).present?
    value = field.field_format == "bool" ? "0" : field.possible_values_options(record).first
    value = value.last if value.is_a?(Array)
    record.custom_field_values = { field.id.to_s => value }
  end
end

def attach(container, author, filename, content, description = nil, content_type = "text/plain")
  attachment = Attachment.new(container: container, author: author, description: description)
  Tempfile.create(["mirror", File.extname(filename)]) do |file|
    file.binmode
    file.write(content)
    file.rewind
    attachment.file = file
    attachment.filename = filename
    attachment.content_type = content_type
    attachment.save!
  end
  attachment
end

owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
User.current = owner

# Global switch of Mirror source (off by default).
Setting.plugin_redmine_mirror = Setting.plugin_redmine_mirror.to_h.merge("source_enabled" => "1")

# Roles: the read-only service role from the guide, and a working role for the demo.
reader_role = Role.find_or_initialize_by(name: "Mirror reader")
reader_role.permissions = %i[view_issues view_private_notes view_time_entries view_issue_watchers
  view_wiki_pages view_wiki_edits view_files view_documents]
reader_role.issues_visibility = "all"
reader_role.users_visibility = "all"
reader_role.time_entries_visibility = "all" if reader_role.respond_to?(:time_entries_visibility=)
reader_role.assignable = false
reader_role.save!
demo_role = Role.find_or_initialize_by(name: "Mirror demo")
demo_role.permissions = %i[view_issues add_issues edit_issues add_issue_notes view_private_notes set_notes_private
  manage_issue_relations manage_subtasks view_issue_watchers add_issue_watchers view_time_entries log_time
  view_wiki_pages view_wiki_edits edit_wiki_pages view_files manage_files view_documents add_documents edit_documents
  manage_categories manage_versions manage_mirror_source]
demo_role.issues_visibility = "all"
demo_role.users_visibility = "all"
demo_role.time_entries_visibility = "all" if demo_role.respond_to?(:time_entries_visibility=)
demo_role.assignable = true
demo_role.save!

# Accounts: the service account, and a local author absent from Redmine 5 (to anonymize).
def local_user(login, firstname, lastname)
  User.find_by(login: login) || User.new(firstname: firstname, lastname: lastname,
    mail: "#{login}@example.invalid", language: "fr").tap do |user|
    user.login = login
    user.admin = false
    user.password = user.password_confirmation = "#{SecureRandom.base64(24)}aA1!"
    user.status = User::STATUS_ACTIVE
    user.save!
  end
end
reader = local_user("mirror-reader", "Mirror", "Reader")
alice = local_user("mirror-demo-alice", "Alice", "Démo")

project = Project.find_by(identifier: "mirror-demo") || Project.new(name: "Mirror demo (migration RM4 → RM5)",
  description: "Projet de démonstration pour tester la migration Mirror vers Redmine 5. Données fictives.",
  is_public: false).tap do |row|
  row.identifier = "mirror-demo"
  row.enabled_module_names = %w[issue_tracking time_tracking documents files wiki mirror_source]
  row.trackers = Tracker.where(id: [1, 2, 3])
  fill_required(row)
  row.save!
end
project.enable_module!(:mirror_source)
(project.mirror_source_setting || project.build_mirror_source_setting).update!(shared_modules: %w[documents])
{ owner => demo_role, alice => demo_role, reader => reader_role }.each do |user, role|
  Member.find_or_create_by!(project: project, user_id: user.id) { |row| row.roles = [role] }
end

unless project.issues.exists?
  back = IssueCategory.create!(project: project, name: "Back-office")
  front = IssueCategory.create!(project: project, name: "Front-office")
  version = Version.create!(project: project, name: "Lot 1", effective_date: Date.new(2026, 12, 15))
  statuses = IssueStatus.where(id: [1, 2, 3]).index_by(&:id)
  activities = TimeEntryActivity.where(id: [9, 20]).to_a
  issues = []
  [[1, "Le formulaire de contact ne s'envoie pas", 2, back, alice],
    [2, "Ajouter l'export PDF des factures", 1, back, owner],
    [3, "Mise à jour des mentions légales", 3, front, owner],
    [1, "Accents mal affichés dans l'en-tête : é è à ç", 2, front, alice],
    [2, "Nouvelle page « Nos offres »", 1, front, owner],
    [3, "Recette du lot 1", 1, nil, owner],
    [3, "Préparer le jeu de données de recette", 2, nil, alice],
    [1, "Erreur 500 sur la recherche", 3, back, owner]].each_with_index do |(tracker, subject, status, category, author), index|
    issue = Issue.new(project: project, tracker_id: tracker, author: author, subject: subject,
      description: "h3. Contexte\n\nDemande de démonstration n°#{index + 1}.\n\n* point *gras*\n* point _italique_\n\n@code@ et lien \"Redmine\":https://www.redmine.org",
      assigned_to: index.even? ? owner : alice, priority: IssuePriority.default, status: statuses.fetch(status),
      category: category, fixed_version: index < 6 ? version : nil, start_date: Date.new(2026, 9, 1) + index,
      estimated_hours: index + 1, done_ratio: status == 3 ? 100 : index * 10)
    fill_required(issue)
    issue.save!
    issues << issue
    TimeEntry.create!(project: project, issue: issue, user: author, activity: activities[index % 2],
      spent_on: Date.new(2026, 10, 1) + index, hours: 0.5 + index * 0.25, comments: "Travail démo #{index + 1}")
  end
  # Parent/child and a relation.
  issues[6].update!(parent_issue_id: issues[5].id)
  IssueRelation.create!(issue_from: issues[0], issue_to: issues[7], relation_type: "relates")
  # Notes (one private), a status change and an attachment in a note.
  journal = issues[0].init_journal(owner, "Reproduit sur la préprod, voir capture.")
  attach(issues[0], owner, "capture-erreur.txt", "Trace de l'erreur : timeout SMTP\n", "Trace")
  issues[0].save!
  issues[0].reload.init_journal(alice, "Note privée : le client n'est pas encore informé.")
  issues[0].current_journal.private_notes = true
  issues[0].save!
  issues[1].init_journal(alice, "Le modèle PDF est joint.")
  issues[1].status = statuses.fetch(2)
  issues[1].save!
  attach(issues[1], alice, "modèle-facture.txt", "Modèle de facture\nTotal TTC : 120 €\n", "Modèle")
  issues[1].watcher_user_ids = [owner.id, alice.id]
  TimeEntry.create!(project: project, user: owner, activity: activities.last, spent_on: Date.new(2026, 10, 10),
    hours: 1, comments: "Pilotage sans demande")
end

unless project.wiki&.pages&.exists?
  # Enabling the module already created the wiki, with "Wiki" as its start page.
  wiki = project.wiki || Wiki.new(project: project)
  wiki.update!(start_page: "Accueil")
  page = wiki.pages.new(title: "Accueil")
  page.content = WikiContent.new(page: page, author: owner, text: "h1. Accueil\n\nWiki du projet de démo.\n\n* [[Procédure de livraison]]")
  page.save!
  page.content.text += "\n\nMis à jour : ajout du lien vers la procédure."
  page.content.author = alice
  page.content.comments = "Lien procédure"
  page.content.save!
  child = wiki.pages.new(title: "Procédure_de_livraison", parent: page)
  child.content = WikiContent.new(page: child, author: alice, text: "h1. Procédure de livraison\n\n# Tag\n# Déploiement\n# Recette")
  child.save!
  attach(child, alice, "checklist-livraison.txt", "[ ] Tag\n[ ] Déploiement\n", "Checklist")
end

unless project.attachments.exists?
  attach(project, owner, "planning-2026.txt", "Planning du projet 2026\n", "Planning (fichier du projet)")
  attach(project.versions.first, owner, "notes-de-version-lot1.txt", "Notes de version du lot 1\n", "Notes de version")
end

unless project.documents.exists?
  categories = DocumentCategory.all.index_by(&:name)
  png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
  [["Architecture Technique", "Architecture de la plateforme", "h2. Vue d'ensemble\n\nVoir les *composants* et le schéma.",
    Time.utc(2026, 9, 3, 10), [[owner, "architecture.txt", "Architecture été\n", "text/plain"], [alice, "schéma.png", png, "image/png"]]],
   ["Manuel Utilisation", "Guide utilisateur", "", Time.utc(2026, 9, 4, 10), []],
   ["Compte-Rendu de réunion", "CR comité de pilotage du 15/09", "* Décision : lot 1 en recette le 15/12\n* Risque : disponibilité client",
    Time.utc(2026, 9, 15, 16), [[alice, "cr-copil-2026-09-15.txt", "Présents : client, prestataire\n", "text/plain"]]],
   ["Cahier de Tests", "Cahier de recette lot 1", "Cas de test du lot 1.", Time.utc(2026, 10, 1, 9),
    [[owner, "cahier-recette.csv", "cas;résultat attendu\nconnexion;OK\n", "text/csv"]]]].each do |category, title, description, created_on, files|
    document = project.documents.create!(category: categories.fetch(category), title: title, description: description)
    document.update_columns(created_on: created_on)
    files.each_with_index do |(author, filename, content, type), index|
      attach(document, author, filename, content, "Fichier #{index + 1}", type).update_columns(created_on: created_on + (index + 1) * 60)
    end
  end
end

reader.api_key # creates the token if missing; never printed
project.reload
puts "mirror-demo (id #{project.id}): #{project.issues.count} issues, #{TimeEntry.where(project: project).count} time entries, " \
  "#{project.wiki&.pages&.count.to_i} wiki pages, #{project.attachments.count + Attachment.where(container: project.versions).count} files, " \
  "#{project.documents.count} documents; Mirror source on, documents shared; members: #{project.members.map { |m| m.user.login }.join(', ')}"
