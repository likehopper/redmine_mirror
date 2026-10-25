# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/04_source_lorem_and_wiki_files.rb
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
# Mirror RM4 -> RM5 migration demo, third batch on the Redmine 4 source: lorem ipsum in the
# contents (notes, descriptions changed through the history, wiki versions, documents)
# and attachments on every wiki page, several shown inline. Runs once.
# No outer transaction: Redmine 4 reuses the disk file of an identical attachment after
# each commit, and chained reuses inside one transaction leave files missing.
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
ASSETS = "/tmp/mirror-demo-assets"

ActionMailer::Base.perform_deliveries = false
Mailer.singleton_class.instance_methods(false).grep(/\Adeliver_/).each { |name| Mailer.define_singleton_method(name) { |*| } }
MattermostDeliverJob.define_singleton_method(:perform_later) { |*| } if defined?(MattermostDeliverJob)

LOREM = [
  "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
  "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
  "Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo.",
  "Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt. Neque porro quisquam est, qui dolorem ipsum quia dolor sit amet.",
  "At vero eos et accusamus et iusto odio dignissimos ducimus qui blanditiis praesentium voluptatum deleniti atque corrupti quos dolores et quas molestias excepturi sint occaecati cupiditate non provident."
].freeze

def lorem(count, offset = 0)
  (0...count).map { |index| LOREM[(offset + index) % LOREM.size] }.join("\n\n")
end

# Textile with a heading, a list and a table around the paragraphs.
def lorem_block(title, offset)
  "h2. #{title}\n\n#{lorem(2, offset)}\n\n* #{LOREM[offset % 5][0, 60]}\n* #{LOREM[(offset + 1) % 5][0, 60]}\n\n" \
    "|_. Lorem |_. Ipsum |\n| dolor | sit amet |\n\n#{lorem(1, offset + 2)}"
end

def attach(container, author, file, name: nil, description: nil)
  name ||= file
  attachment = Attachment.new(container: container, author: author, description: description)
  attachment.file = File.open(File.join(ASSETS, file), "rb")
  attachment.filename = name
  attachment.content_type = Redmine::MimeType.of(name) || "application/octet-stream"
  attachment.save!
  attachment
end

project = Project.find_by!(identifier: "mirror-demo")
abort "Lorem ipsum already added" if Journal.where(journalized: project.issues).where("notes LIKE ?", "%Lorem ipsum dolor%").exists?
owner = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
alice = User.find_by!(login: "mirror-demo-alice")
User.current = owner

# Issues: a lorem ipsum note on every issue; the description of open ones grows through
# the history (a description detail), the closed ones keep theirs.
project.issues.order(:id).each_with_index do |issue, index|
  author = index.even? ? owner : alice
  issue.reload.init_journal(author, "Lorem ipsum : compte rendu n°#{index + 1}.\n\n#{lorem(1 + index % 3, index)}")
  issue.description = "#{issue.description}\n\n#{lorem_block('Lorem ipsum', index)}" unless issue.closed?
  issue.save!
end

# Wiki: a new version of every page with a lorem ipsum section, and files on each page,
# several shown inline in that section.
files = {
  "Accueil" => [["LOGO-MAJUSCULES.PNG", nil, true], ["logo-vectoriel.svg", nil, false]],
  "Documentation" => [["specification-fonctionnelle.pdf", nil, false], ["recette.xlsx", nil, false]],
  "Architecture" => [["compte-rendu réunion.docx", nil, false]],
  "Détails_techniques" => [["config-exemple.json", nil, false], ["capture-ecran.jpg", "capture-détails.jpg", true]],
  "Guide_d'installation" => [["capture-ecran.jpg", nil, true], ["livrables-lot1.zip", nil, false], ["config-exemple.json", "parametres.json", false]],
  "Nouveau_titre" => [["capture-ecran-v2.jpg", "capture.jpg", true]],
  "Page_protégée" => [["Devis client (v2) 2026.pdf", nil, false]],
  "Réunions_2026" => [["compte-rendu réunion.docx", nil, false], ["schema-architecture.png", "schéma réunion.png", true]],
  "Page_longue" => [["photo-lourde.jpg", nil, true]],
  "Page_Markdown" => [["animation-etapes.gif", nil, true]],
  "Procédure_de_livraison" => [["specification-fonctionnelle.pdf", "procédure.pdf", false], ["animation-etapes.gif", "étapes.gif", true]]
}
project.wiki.pages.order(:id).each_with_index do |page, index|
  author = index.even? ? alice : owner
  inline = []
  files.fetch(page.title, []).each do |file, name, shown|
    attachment = attach(page, author, file, name: name, description: "Pièce jointe de la page #{page.pretty_title}")
    inline << (attachment.filename.match?(/\.(png|jpe?g|gif)\z/i) ? "!#{attachment.filename}!" : "attachment:\"#{attachment.filename}\"") if shown
    inline << "attachment:\"#{attachment.filename}\"" unless shown
  end
  content = page.reload.content
  content.text = "#{content.text}\n\n#{lorem_block('Lorem ipsum', index)}\n\n#{inline.join("\n\n")}"
  content.author = author
  content.comments = "Ajout lorem ipsum et pièces jointes"
  content.save!
end

# Documents: lorem ipsum in every description.
project.documents.order(:id).each_with_index do |document, index|
  document.update!(description: "#{document.description}\n\n#{lorem_block('Lorem ipsum', index)}")
end

# Disk files: any row left on a reused file that is gone points to an identical one.
missing = Attachment.where(author_id: [owner.id, alice.id]).where("created_on > ?", 1.hour.ago).reject { |row| File.exist?(row.diskfile) }
missing.each do |row|
  good = Attachment.where(digest: row.digest, filesize: row.filesize).detect { |other| File.exist?(other.diskfile) }
  row.update_columns(disk_directory: good.disk_directory, disk_filename: good.disk_filename) if good
end
project.reload
puts "Lorem ipsum added: #{project.issues.count} issues noted, #{project.wiki.pages.count} wiki pages " \
  "(#{Attachment.where(container: project.wiki.pages).count} files), #{project.documents.count} documents; " \
  "missing files repaired: #{missing.size}"
