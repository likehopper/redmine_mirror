# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/03_source_edge_cases.rb
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
# Mirror RM4 -> RM5 migration demo, edge cases (second batch) on the Redmine 4 source.
# Extends the "mirror-demo" project seeded by rm4_mirror_demo_seed.rb; files come from
# ASSETS (generated demo images, PDFs, office files). Runs once: skipped when the
# "[Cas]" issues exist. Touches only mirror-demo, mirror-demo-externe and the demo users.
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
ASSETS = "/tmp/mirror-demo-assets"
SOURCE_URL = ENV.fetch("MIRROR_DEMO_SOURCE_URL")

# No mail and no Mattermost post from this run (this process only).
ActionMailer::Base.perform_deliveries = false
Mailer.singleton_class.instance_methods(false).grep(/\Adeliver_/).each { |name| Mailer.define_singleton_method(name) { |*| } }
MattermostDeliverJob.define_singleton_method(:perform_later) { |*| } if defined?(MattermostDeliverJob)

project = Project.find_by!(identifier: "mirror-demo")
abort "Edge cases already seeded" if project.issues.where("subject LIKE ?", "[Cas]%").exists?
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
alice = User.find_by!(login: "mirror-demo-alice")
User.current = owner
demo_role = Role.find_by!(name: "Mirror demo")
first = project.issues.order(:id).first

def fill_required(record)
  record.available_custom_fields.select(&:is_required?).each do |field|
    next if record.custom_field_value(field).present?
    value = field.field_format == "bool" ? "0" : field.possible_values_options(record).first
    value = value.last if value.is_a?(Array)
    record.custom_field_values = { field.id.to_s => value }
  end
end

def attach(container, author, file, name: nil, description: nil, content: nil)
  name ||= file
  attachment = Attachment.new(container: container, author: author, description: description)
  Tempfile.create(["mirror", File.extname(name)]) do |tmp|
    tmp.binmode
    tmp.write(content || File.binread(File.join(ASSETS, file)))
    tmp.rewind
    attachment.file = tmp
    attachment.filename = name
    attachment.content_type = Redmine::MimeType.of(name) || "application/octet-stream"
    attachment.save!
  end
  attachment
end

def issue!(project, attributes)
  issue = Issue.new({ project: project, tracker_id: 1, author: User.current, priority: IssuePriority.default,
    status_id: 1 }.merge(attributes))
  fill_required(issue)
  issue.save!
  issue
end

def note!(issue, user, notes = "", at: nil, private_notes: false)
  issue.reload.init_journal(user, notes)
  issue.current_journal.private_notes = private_notes
  yield issue if block_given?
  issue.save!
  journal = issue.journals.order(:id).last
  journal.update_columns(created_on: at) if at
  journal
end

def backdate(record, at)
  record.update_columns(created_on: at, updated_on: at)
end

# A local author who leaves: active while writing, locked at the end.
bob = User.find_by(login: "mirror-demo-bob") || User.new(firstname: "Bob", lastname: "Parti",
  mail: "mirror-demo-bob@example.invalid", language: "fr").tap do |user|
  user.login = "mirror-demo-bob"
  user.password = user.password_confirmation = "#{SecureRandom.base64(24)}aA1!"
  user.save!
end
Member.find_or_create_by!(project: project, user_id: bob.id) { |row| row.roles = [demo_role] }

# Another project the reader cannot see: cross-project relation, reference and shared version.
external = Project.find_by(identifier: "mirror-demo-externe") || Project.new(name: "Mirror demo externe (non migré)",
  is_public: false).tap do |row|
  row.identifier = "mirror-demo-externe"
  row.enabled_module_names = %w[issue_tracking]
  row.trackers = Tracker.where(id: [1])
  fill_required(row)
  row.save!
end
Member.find_or_create_by!(project: external, user_id: owner.id) { |row| row.roles = [demo_role] }
outside = issue!(external, subject: "Demande d'un autre projet", description: "Hors du périmètre migré.")
shared_version = Version.create!(project: external, name: "Version partagée (système)", sharing: "system",
  effective_date: Date.new(2026, 11, 30))

# References: categories (one with a default assignee) and versions (closed, locked).
cat_api = IssueCategory.create!(project: project, name: "API & intégrations", assigned_to: alice)
lot1 = project.versions.find_by!(name: "Lot 1")
lot0 = Version.create!(project: project, name: "Lot 0 (fermée)", effective_date: Date.new(2026, 6, 30))
locked_version = Version.create!(project: project, name: "Lot 0bis (verrouillée)", effective_date: Date.new(2026, 7, 31))

images = issue!(project, tracker_id: 2, subject: "[Cas] Images intégrées et pièces jointes variées", author: owner,
  assigned_to: alice, category: cat_api, fixed_version: lot1, description: "temp")
schema = attach(images, owner, "schema-architecture.png", description: "Schéma d'architecture")
capture = attach(images, owner, "capture-ecran.jpg", description: "Capture initiale")
attach(images, owner, "LOGO-MAJUSCULES.PNG")
attach(images, owner, "animation-etapes.gif", description: "GIF animé")
attach(images, owner, "logo-vectoriel.svg", description: "SVG")
devis = attach(images, alice, "Devis client (v2) 2026.pdf", description: "Nom avec espaces et parenthèses")
attach(images, alice, "specification-fonctionnelle.pdf", description: "PDF de 3 pages")
attach(images, alice, "compte-rendu réunion.docx")
attach(images, alice, "recette.xlsx")
attach(images, alice, "livrables-lot1.zip")
attach(images, alice, "config-exemple.json")
attach(images, bob, "photo-lourde.jpg", description: "Fichier lourd (1,2 Mo)")
images.update_column(:description, <<~TEXTILE)
  h2. Images intégrées

  Image en ligne : !schema-architecture.png!

  Alignée à droite avec titre : !>capture-ecran.jpg(Capture d'écran)!

  Extension en majuscules : !LOGO-MAJUSCULES.PNG! et GIF animé : !animation-etapes.gif!

  Miniature (macro) : {{thumbnail(schema-architecture.png, size=200, title=Schéma)}}

  Image externe : !https://www.redmine.org/images/redmine-logo.png!

  Image par URL absolue du serveur source : !#{SOURCE_URL}/attachments/download/#{schema.id}/schema-architecture.png!

  Image par URL relative : !/attachments/download/#{capture.id}/capture-ecran.jpg!

  h2. Liens vers des pièces jointes

  * attachment:"Devis client (v2) 2026.pdf"
  * attachment:specification-fonctionnelle.pdf
  * "Le devis (lien absolu)":#{SOURCE_URL}/attachments/download/#{devis.id}/Devis%20client%20(v2)%202026.pdf
  * "La spécification (lien relatif)":/attachments/#{devis.id}
TEXTILE
# Same file name twice: a second capture-ecran.jpg in a note that shows it inline.
note!(images, alice, "Nouvelle version de la capture (même nom de fichier) :\n\n!capture-ecran.jpg!", at: Time.utc(2026, 9, 20, 9)) do |issue|
  issue.attachments << attach(nil, alice, "capture-ecran-v2.jpg", name: "capture-ecran.jpg", description: "Capture v2, même nom")
end
# A file added then removed: both history details.
removed = attach(nil, owner, "recette.csv", name: "provisoire.csv")
note!(images, owner, "Ajout d'un fichier provisoire.") { |issue| issue.attachments << removed }
images.reload.init_journal(owner, "Suppression du fichier provisoire.")
images.attachments.delete(removed)
images.save!

textile = issue!(project, tracker_id: 2, subject: "[Cas] Mise en forme Textile complète et références", author: owner,
  assigned_to: owner, fixed_version: lot1, description: "temp")
textile.update_column(:description, <<~TEXTILE)
  {{toc}}

  h1. Titre 1

  h2. Titre 2

  h3. Titre 3

  Texte *gras*, _italique_, -barré-, +souligné+, ??citation??, ^exposant^, ~indice~, %{color:red}rouge%, @code en ligne@.
  Caractères : é è à ç œ € « guillemets » — tiret, emoji 🚀 ✅, entités &amp; &lt;b&gt;, HTML brut <b>gras HTML</b>.

  p>. Paragraphe aligné à droite.

  p=. Paragraphe centré.

  bq. Citation en bloc
  sur deux lignes.

  * Liste
  ** imbriquée
  *** sur trois niveaux
  # Liste numérotée
  ## sous-élément

  |_. En-tête 1 |_. En-tête 2 |_. En-tête 3 |
  | cellule | *gras* | 12,5 € |
  |\\2. fusion sur deux colonnes | fin |
  |/2. fusion verticale | a | b |
  | c | d |

  bc. Bloc de code Textile avec #{first.id} et ##{first.id} : ces références ne doivent pas changer.

  <pre><code class="ruby">
  # code Ruby coloré, la référence ##{first.id} reste telle quelle
  def demo = puts("é")
  </code></pre>

  {{collapse(Détails repliables)
  Contenu masqué avec une référence ##{first.id}.
  }}

  h2. Références

  * Demande du projet : ##{first.id}, avec aperçu : ###{first.id}, ####{first.id}
  * Note précise : ##{first.id}#note-1
  * Demande hors projet (non migrée) : ##{outside.id}
  * URL source d'une demande : #{SOURCE_URL}/issues/#{first.id}
  * Wiki : [[Accueil]], [[Procédure_de_livraison|la procédure]], [[mirror-demo:Accueil|wiki par projet]], [[Page inexistante]]
  * Document : document##{project.documents.first.id}, document:"Guide utilisateur"
  * Version : version##{lot1.id}, version:"Lot 1"
  * Projet : project:mirror-demo
  * Utilisateur : user##{alice.id}, @#{owner.login}
  * Lien externe : "Redmine":https://www.redmine.org et URL nue https://www.redmine.org/projects/redmine/wiki

  Note de bas de page[1].

  fn1. Texte de la note de bas de page.
TEXTILE

markdown = issue!(project, tracker_id: 3, subject: "[Cas] Description écrite en Markdown dans un projet Textile",
  author: alice, description: <<~MARKDOWN)
  ## Titre Markdown

  - élément de liste
  - autre élément

  **gras** et _italique_, `code`, [lien](https://www.redmine.org) et ##{first.id}

  ```ruby
  puts "bloc de code ##{first.id}"
  ```

  > citation Markdown
MARKDOWN
plain = issue!(project, tracker_id: 3, subject: "[Cas] Texte brut et description vide", author: alice,
  description: "Texte brut sans mise en forme.\nDeuxième ligne.\n\nTroisième paragraphe avec une URL https://example.com.")
issue!(project, tracker_id: 3, subject: "[Cas] Description vide", author: alice, description: "")
long = issue!(project, tracker_id: 1, author: owner, description: "Sujet de 255 caractères.",
  subject: ("[Cas] Sujet très long avec caractères spéciaux <script>alert('x')</script> & \"guillemets\" € œ " * 4)[0, 255])

secret = issue!(project, tracker_id: 1, subject: "[Cas] Demande privée", author: alice, assigned_to: alice,
  is_private: true, description: "Visible seulement des membres autorisés.")
note!(secret, alice, "Note dans une demande privée.")

closed = issue!(project, tracker_id: 1, subject: "[Cas] Demande fermée dans une version fermée", author: owner,
  fixed_version: lot0, status_id: 7, done_ratio: 100, description: "Fermée - Validée.")
on_locked = issue!(project, tracker_id: 3, subject: "[Cas] Demande sur une version verrouillée", author: owner,
  fixed_version: locked_version, description: "Version verrouillée après coup.")
on_shared = issue!(project, tracker_id: 3, subject: "[Cas] Demande sur une version partagée d'un autre projet",
  author: owner, fixed_version: shared_version, description: "Version partagée au niveau système.")
rejected = issue!(project, tracker_id: 1, subject: "[Cas] Demande rejetée", author: bob, status_id: 6,
  priority: IssuePriority.find_by(name: "Urgente"), description: "Statut Rejetée-Abandonnée, priorité Urgente.")
lot0.update!(status: "closed")
locked_version.update!(status: "locked")

# Hierarchy over three levels, the child created before its parent.
child = issue!(project, tracker_id: 3, subject: "[Cas] Sous-tâche créée avant son parent", author: alice)
parent = issue!(project, tracker_id: 2, subject: "[Cas] Parent créé après sa sous-tâche", author: owner)
root = issue!(project, tracker_id: 2, subject: "[Cas] Racine d'une hiérarchie à trois niveaux", author: owner)
parent.reload.update!(parent_issue_id: root.id)
child.reload.update!(parent_issue_id: parent.id)

# Relations of every type, one to an issue the reader cannot see.
IssueRelation.create!(issue_from: root, issue_to: closed, relation_type: "blocks")
IssueRelation.create!(issue_from: closed, issue_to: on_locked, relation_type: "precedes", delay: 2)
IssueRelation.create!(issue_from: plain, issue_to: markdown, relation_type: "duplicates")
IssueRelation.create!(issue_from: textile, issue_to: images, relation_type: "copied_to")
IssueRelation.create!(issue_from: images, issue_to: outside, relation_type: "relates")

# A rich history, backdated: every kind of detail, edited and private notes, many notes.
history = issue!(project, tracker_id: 1, subject: "[Cas] Historique complet", author: bob, assigned_to: bob,
  category: project.issue_categories.find_by(name: "Back-office"), start_date: Date.new(2019, 3, 1),
  estimated_hours: 4, description: "Description initiale.")
backdate(history, Time.utc(2019, 3, 1, 9))
impact = IssueCustomField.find_by(name: "Impact")
note!(history, owner, "Prise en compte.", at: Time.utc(2019, 3, 2, 10)) do |issue|
  issue.status_id = 2
  issue.assigned_to = alice
end
note!(history, alice, "", at: Time.utc(2019, 3, 3, 10)) do |issue|
  issue.subject = "[Cas] Historique complet (sujet modifié)"
  issue.description = "Description initiale.\n\nComplétée avec le contexte."
  issue.priority = IssuePriority.find_by(name: "Basse")
  issue.category = project.issue_categories.find_by(name: "Front-office")
  issue.fixed_version = lot1
  issue.done_ratio = 50
  issue.due_date = Date.new(2019, 4, 30)
  issue.estimated_hours = 6.5
  values = impact&.possible_values_options(issue)&.map { |value| value.is_a?(Array) ? value.last : value }
  issue.custom_field_values = { impact.id.to_s => values[1] } if values && values.size > 1
end
note!(history, bob, "Voir la capture :\n\n!trace.png!", at: Time.utc(2019, 3, 4, 10)) do |issue|
  issue.attachments << attach(nil, bob, "schema-architecture.png", name: "trace.png", description: "Capture dans une note")
end
note!(history, alice, "Note privée : à valider en interne.", at: Time.utc(2019, 3, 5, 10), private_notes: true)
edited = note!(history, owner, "Note avant modification.", at: Time.utc(2019, 3, 6, 10))
edited.update_columns(notes: "Note modifiée après coup (texte corrigé).")
edited.update_columns(updated_on: Time.utc(2019, 3, 7, 10), updated_by_id: alice.id) if edited.respond_to?(:updated_by_id)
note!(history, owner, "", at: Time.utc(2019, 3, 8, 10)) { |issue| issue.is_private = true }
note!(history, owner, "", at: Time.utc(2019, 3, 8, 11)) { |issue| issue.is_private = false }
note!(history, owner, "", at: Time.utc(2019, 3, 9, 10)) { |issue| issue.parent_issue_id = root.id }
User.current = owner
IssueRelation.create!(issue_from: history, issue_to: plain, relation_type: "relates")
20.times do |index|
  note!(history, [owner, alice, bob][index % 3], "Échange n°#{index + 1} : suivi de la demande.", at: Time.utc(2019, 4, 1, 9) + index.days)
end
history.watcher_user_ids = [owner.id, alice.id, bob.id]
images.watcher_user_ids = [alice.id, bob.id]

# Time entries: decimals, past years, an unmapped activity, on a child, by the leaving author.
[[history, bob, 9, Date.new(2019, 3, 4), 0.25, "Analyse rapide"],
  [history, alice, 9, Date.new(2019, 3, 5), 7.5, "Développement — journée complète"],
  [child, alice, 20, Date.new(2026, 10, 2), 1.75, "Temps sur une sous-tâche"],
  [images, owner, 8, Date.new(2026, 10, 3), 2, "Conception (activité non encore mappée)"],
  [nil, bob, 20, Date.new(2025, 12, 31), 3, "Temps projet du 31/12"]].each do |issue, user, activity, date, hours, comments|
  # A local plugin forbids months already validated: create now, then move to the historical date.
  entry = TimeEntry.create!(project: project, issue: issue, user: user, activity_id: activity, spent_on: Date.new(2026, 10, 15),
    hours: hours, comments: comments)
  entry.update_columns(spent_on: date, tyear: date.year, tmonth: date.month, tweek: date.cweek)
end
note!(history, owner, "Clôture.", at: Time.utc(2019, 5, 2, 10)) { |issue| issue.status_id = 3; issue.done_ratio = 100 }

# Wiki: hierarchy, many versions with a deleted one, rename with redirect, protected page,
# inline images, macros, accents and apostrophes in titles, a long page.
wiki = project.wiki
home = wiki.find_page("Accueil")
def page!(wiki, title, author, text, parent: nil)
  page = wiki.pages.new(title: title, parent: parent)
  page.content = WikiContent.new(page: page, author: author, text: text)
  page.save!
  page
end
def revise!(page, author, text, comment)
  content = page.reload.content
  content.text = text
  content.author = author
  content.comments = comment
  content.save!
end
documentation = page!(wiki, "Documentation", owner, "h1. Documentation\n\n{{child_pages}}", parent: home)
architecture = page!(wiki, "Architecture", alice, "temp", parent: documentation)
attach(architecture, alice, "schema-architecture.png")
attach(architecture, alice, "animation-etapes.gif")
attach(architecture, alice, "specification-fonctionnelle.pdf")
revise!(architecture, alice, <<~TEXTILE, "Schémas")
  {{>toc}}

  h1. Architecture

  !schema-architecture.png!

  h2. Déploiement

  !animation-etapes.gif!

  Voir attachment:specification-fonctionnelle.pdf et la demande ##{images.id}.

  |_. Composant |_. Technologie |
  | Front | Vue |
  | API | Ruby |
TEXTILE
page!(wiki, "Détails_techniques", bob, "h1. Détails techniques\n\nNiveau 4 de la hiérarchie.\n\nbc. config: { lot: 1 }", parent: architecture)
install = page!(wiki, "Guide_d'installation", owner, "h1. Guide d'installation\n\nVersion 1.", parent: documentation)
[[alice, "Ajout des prérequis"], [bob, "Correction"], [owner, "Étapes"], [alice, "Captures"], [owner, "Relecture"]].each_with_index do |(author, comment), index|
  revise!(install, author, "h1. Guide d'installation\n\n{{toc}}\n\n" + (1..index + 2).map { |step| "h2. Étape #{step}\n\nContenu de l'étape #{step}." }.join("\n\n"), comment)
end
install.reload.content.versions.find_by(version: 3)&.destroy # deleted version: a gap in the history
old = page!(wiki, "Ancien_titre", owner, "h1. Page renommée\n\nCette page s'appelait « Ancien titre ».", parent: home)
old.reload.title = "Nouveau_titre"
old.save!
protected_page = page!(wiki, "Page_protégée", owner, "h1. Page protégée\n\nModifiable seulement avec le droit « Protéger les pages ».", parent: home)
protected_page.update!(protected: true)
page!(wiki, "Réunions_2026", alice, <<~TEXTILE, parent: home)
  h1. Réunions 2026

  {{include(Guide_d'installation)}}

  * [[Nouveau_titre]] (page renommée)
  * [[Ancien_titre]] (ancien lien, redirigé)
  * [[Architecture#Déploiement|ancre]]
  * document##{project.documents.first.id}, version:"Lot 1", ##{history.id}
TEXTILE
page!(wiki, "Page_Markdown", alice, "## Écrite en Markdown\n\n- point\n- autre\n\n```\ncode\n```\n\n[lien](https://www.redmine.org)", parent: home)
page!(wiki, "Page_longue", owner, (1..60).map { |n| "h2. Section #{n}\n\n" + ("Texte de remplissage é à ç. " * 12) }.join("\n\n"), parent: home)
revise!(home, owner, home.reload.content.text + "\n\n* [[Documentation]]\n* [[Réunions_2026]]\n* [[Page_longue]]", "Sommaire")

# Documents: inline image in the description, several office files, a backdated one.
categories = DocumentCategory.all.index_by(&:name)
spec_doc = project.documents.create!(category: categories.fetch("Expression de Besoins"), title: "Spécification fonctionnelle",
  description: "Schéma : !schema-architecture.png!\n\nVoir ##{textile.id} et [[Architecture]].")
attach(spec_doc, owner, "schema-architecture.png")
attach(spec_doc, owner, "specification-fonctionnelle.pdf")
attach(spec_doc, alice, "compte-rendu réunion.docx")
attach(spec_doc, alice, "recette.xlsx")
old_doc = project.documents.create!(category: categories.fetch("Proposition commerciale"), title: "Proposition commerciale 2019",
  description: "Document ancien (2019), fichier au nom avec espaces.")
old_doc.update_columns(created_on: Time.utc(2019, 1, 15, 9))
attach(old_doc, bob, "Devis client (v2) 2026.pdf").update_columns(created_on: Time.utc(2019, 1, 15, 9, 5))

# Files module: on the project and on two versions.
attach(project, owner, "livrables-lot1.zip", description: "Livrables")
attach(lot1, alice, "specification-fonctionnelle.pdf", description: "Spécification du lot 1")
attach(lot0, owner, "Devis client (v2) 2026.pdf", description: "Version fermée")

bob.update_column(:status, User::STATUS_LOCKED)
project.reload
puts "Edge cases ready in mirror-demo: #{project.issues.count} issues, #{project.wiki.pages.count} wiki pages, " \
  "#{project.documents.count} documents, #{Attachment.where(container: project.versions).count + project.attachments.count} files; " \
  "bob locked; external issue ##{outside.id}"
