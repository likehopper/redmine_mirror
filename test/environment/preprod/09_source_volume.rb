# frozen_string_literal: true
# File: redmine_mirror/test/environment/preprod/09_source_volume.rb
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
# Mirror RM4 -> RM5 migration demo, volume batch on the Redmine 4 source: about 200 "[Volume]" issues
# with history, files, relations, hierarchy, tags, sprints, watchers, about 600 time
# entries, wiki pages, news, documents and saved queries, plus edge cases (moved issue,
# reopened issue, category of another project, issue with 100 notes, long description,
# 5 MB file, values not mapped yet). Deterministic (seed 42). Each section runs once
# (markers), without an outer transaction (Redmine 4 reuses identical files on commit).
# Ruby 2.6 (Redmine 4): no endless methods, no filter_map, no tally.
abort "Redmine 4 source only" unless Redmine::VERSION::MAJOR == 4
RNG = Random.new(42)

ActionMailer::Base.perform_deliveries = false
Mailer.singleton_class.instance_methods(false).grep(/\Adeliver_/).each { |name| Mailer.define_singleton_method(name) { |*| } }
MattermostDeliverJob.define_singleton_method(:perform_later) { |*| } if defined?(MattermostDeliverJob)

LOREM = ["Lorem ipsum dolor sit amet, consectetur adipiscing elit.", "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
  "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.", "Duis aute irure dolor in reprehenderit in voluptate velit esse.",
  "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia."].freeze

PROJECT = Project.find_by!(identifier: "mirror-demo")
EXTERNAL = Project.find_by!(identifier: "mirror-demo-externe")
OWNER = User.find_by!(login: ENV.fetch("MIRROR_DEMO_OWNER"))
ALICE = User.find_by!(login: "mirror-demo-alice")
BOB = User.find_by!(login: "mirror-demo-bob")
PEOPLE = [OWNER, ALICE, BOB].freeze
User.current = OWNER
STARTED = Time.now

def pick(list)
  list[RNG.rand(list.size)]
end

def lorem(count)
  Array.new(count) { pick(LOREM) }.join(" ")
end

def fill_required(record)
  record.available_custom_fields.select(&:is_required?).each do |field|
    next if record.custom_field_value(field).present?
    value = field.field_format == "bool" ? "0" : field.possible_values_options(record).first
    value = value.last if value.is_a?(Array)
    record.custom_field_values = { field.id.to_s => value }
  end
end

def file!(container, author, name, body, description = nil)
  attachment = Attachment.new(container: container, author: author, description: description)
  Tempfile.create(["mirror", File.extname(name)]) do |tmp|
    tmp.binmode
    tmp.write(body)
    tmp.rewind
    attachment.file = tmp
    attachment.filename = name
    attachment.content_type = Redmine::MimeType.of(name) || "application/octet-stream"
    attachment.save!
  end
  attachment
end

def issue!(project, attributes)
  issue = Issue.new({ project: project, author: OWNER, priority: IssuePriority.default, status_id: 1 }.merge(attributes))
  fill_required(issue)
  issue.save!
  issue
end

def journal!(issue, user, notes, at, private_notes: false)
  issue.reload.init_journal(user, notes)
  issue.current_journal.private_notes = private_notes
  yield issue if block_given?
  issue.save!
  journal = issue.journals.order(:id).last
  journal.update_columns(created_on: at)
  journal
end

# Historical time, as the history holds it: a local plugin's validated months and locked authors
# are rules for new entries, not for the past.
def time!(project, issue, user, activity_id, date, hours, comments)
  entry = TimeEntry.new(project: project, issue: issue, user: user, activity_id: activity_id, spent_on: date, hours: hours, comments: comments)
  entry.save!(validate: false)
  entry
end

# A section runs once: its marker says whether it is already there.
def section(name, done)
  if done.call
    puts "#{name}: already there"
  else
    yield
    puts "#{name}: done (#{(Time.now - STARTED).round}s)"
  end
end

statuses = { new: 1, progress: 2, resolved: 3, question: 4, rejected: 6, closed: 7 }
priorities = [3, 4, 4, 4, 6, 7]
activities = [9, 9, 20, 8, 167]
trackers = PROJECT.trackers.pluck(:id)
versions = PROJECT.versions.where(status: "open").to_a
categories = PROJECT.issue_categories.to_a
sprints = defined?(::Sprint) ? ::Sprint.where(project_id: PROJECT.id, is_product_backlog: false).where.not(status: "closed").to_a : []
story_points = (Scrum::Setting.story_points_custom_field_id rescue nil)

# 1. About 200 issues, each with a history, some with files, tags, sprint and watchers.
section("Issues", -> { PROJECT.issues.where("subject LIKE ?", "[Volume] Demande 001%").exists? }) do
  base = Time.utc(2025, 1, 6, 9)
  issues = []
  200.times do |n|
    created = base + (n * 37).hours
    status = pick([:new, :new, :progress, :progress, :resolved, :closed, :rejected, :question])
    issue = issue!(PROJECT, subject: format("[Volume] Demande %03d — %s", n + 1, lorem(1)[0, 60]),
      tracker_id: pick(trackers), author: pick(PEOPLE), assigned_to: pick([OWNER, ALICE, nil]),
      priority_id: pick(priorities), category: pick(categories + [nil]), fixed_version: pick(versions + [nil]),
      description: "h3. Contexte\n\n#{lorem(3)}\n\n* #{lorem(1)}\n* #{lorem(1)}\n\nVoir ##{issues.last&.id || PROJECT.issues.minimum(:id)}.",
      start_date: created.to_date, estimated_hours: [nil, 1, 2.5, 4, 8][n % 5], done_ratio: 0)
    issue.update_columns(created_on: created, updated_on: created)
    # History: 1 to 6 journals, status changes, assignee changes, notes (some private).
    (1 + n % 6).times do |step|
      journal!(issue, pick(PEOPLE), step.even? ? lorem(2) : "", created + (step + 1).days, private_notes: (n + step) % 17 == 0) do |row|
        row.status_id = statuses.fetch(status) if step == (n % 6)
        row.assigned_to = pick([OWNER, ALICE]) if step == 1
        row.done_ratio = [row.done_ratio + 20, 100].min if step.odd?
      end
    end
    file!(issue, pick(PEOPLE), "rapport-#{n + 1}.txt", "Rapport #{n + 1}\n#{lorem(4)}\n", "Rapport n°#{n + 1}") if n % 4 == 0
    file!(issue, ALICE, "export-#{n + 1}.csv", "id;valeur\n#{n};#{n * 3}\n") if n % 10 == 0
    issue.watcher_user_ids = PEOPLE.first(1 + n % 3).map(&:id) if n % 3 == 0
    issue.tag_list = [pick(%w[urgent client front back recette]), pick(["Lot 1", "dette technique", "UX"])] if n % 5 == 0 && issue.respond_to?(:tag_list=)
    issue.save_tags if issue.respond_to?(:save_tags) && n % 5 == 0
    if sprints.any?
      issue.update_columns(sprint_id: n % 4 == 0 ? nil : pick(sprints).id, position: 1000 + n)
      if story_points && n % 3 == 0
        value = CustomValue.find_or_initialize_by(customized_type: "Issue", customized_id: issue.id, custom_field_id: story_points)
        value.value = %w[1 2 3 5 8 13 0.5][n % 7]
        value.save!(validate: false)
      end
    end
    issues << issue
  end
  # Hierarchy (chains of 3) and relations of several types.
  refused = 0
  issues.each_slice(3).first(20).each do |parent, child, grandchild|
    next unless grandchild
    refused += 1 unless child.reload.update(parent_issue_id: parent.id)
    refused += 1 unless grandchild.reload.update(parent_issue_id: child.id)
  end
  puts "hierarchy links refused by Redmine: #{refused}"
  %w[relates blocks precedes duplicates relates copied_to].each_with_index do |type, index|
    10.times do |k|
      from, to = issues[60 + index * 20 + k], issues[61 + index * 20 + k + 5]
      next unless from && to && from != to
      IssueRelation.create(issue_from: from, issue_to: to, relation_type: type, delay: (type == "precedes" ? 1 : nil))
    end
  end
  # Time: about 600 entries over 2025 and 2026, some on project, an unmapped activity.
  600.times do |k|
    issue = k % 9 == 0 ? nil : issues[k % issues.size]
    time!(PROJECT, issue, pick(PEOPLE), pick(activities), Date.new(2025, 1, 6) + (k * 11 % 600), [0.25, 0.5, 1, 1.5, 2, 3.75, 7.5][k % 7], "Saisie #{k + 1} #{lorem(1)[0, 40]}")
  end
end

# 2. Edge cases.
section("Edge cases", -> { Issue.where("subject LIKE ?", "[Volume] Cas déplacée%").exists? }) do
  # Created in the external project then moved: the history keeps a project change.
  moved = issue!(EXTERNAL, subject: "[Volume] Cas déplacée depuis un autre projet", tracker_id: 1, description: "Créée dans mirror-demo-externe.")
  moved.reload.init_journal(OWNER, "Déplacée vers le projet de démo.")
  moved.project = PROJECT
  moved.save!
  # Closed then reopened.
  reopened = issue!(PROJECT, subject: "[Volume] Cas fermée puis rouverte", tracker_id: trackers.first, description: "Rouverte après recette KO.")
  journal!(reopened, ALICE, "Fermée.", Time.utc(2026, 3, 1, 9)) { |row| row.status_id = statuses[:closed] }
  journal!(reopened, OWNER, "Rouverte : la recette a échoué.", Time.utc(2026, 3, 2, 9)) { |row| row.status_id = statuses[:progress] }
  # A category owned by another project (moved issues, plugins).
  other = EXTERNAL.issue_categories.first || IssueCategory.create!(project: EXTERNAL, name: "Catégorie externe")
  cross = issue!(PROJECT, subject: "[Volume] Cas catégorie d'un autre projet", tracker_id: trackers.first, description: "Catégorie de mirror-demo-externe.")
  cross.update_columns(category_id: other.id)
  # 100 notes.
  chatty = issue!(PROJECT, subject: "[Volume] Cas cent notes", tracker_id: trackers.first, description: "Une demande très commentée.")
  100.times { |k| journal!(chatty, PEOPLE[k % 3], "Note #{k + 1} : #{lorem(1)}", Time.utc(2026, 1, 1, 9) + k.hours) }
  # A long description (about 60 KB) and a 5 MB file.
  long = issue!(PROJECT, subject: "[Volume] Cas description très longue", tracker_id: trackers.first,
    description: (1..220).map { |k| "h3. Paragraphe #{k}\n\n#{lorem(3)}" }.join("\n\n")[0, 45_000])
  file!(long, OWNER, "gros-fichier-5mo.bin", Random.new(7).bytes(5 * 1024 * 1024), "Fichier de 5 Mo")
  # Values not mapped yet on the destination: status Commentaire - Question, priority
  # Immédiate, activity Analyse.
  unmapped = issue!(PROJECT, subject: "[Volume] Cas valeurs non mappées", tracker_id: trackers.first, status_id: statuses[:question],
    priority_id: 7, description: "Statut, priorité et activité sans correspondance.")
  time!(PROJECT, unmapped, OWNER, 167, Date.new(2026, 2, 2), 2, "Analyse (activité non mappée)")
end

# 3. Wiki: 20 pages in a hierarchy, several versions, files.
section("Wiki", -> { PROJECT.wiki.pages.where(title: "Volume_Wiki").exists? }) do
  wiki = PROJECT.wiki
  root = wiki.pages.new(title: "Volume_Wiki", parent: wiki.find_page("Accueil"))
  root.content = WikiContent.new(page: root, author: OWNER, text: "h1. Volume\n\n{{child_pages}}")
  root.save!
  parent = root
  20.times do |k|
    page = wiki.pages.new(title: format("Volume_page_%02d", k + 1), parent: k % 5 == 0 ? root : parent)
    page.content = WikiContent.new(page: page, author: pick(PEOPLE), text: "h1. Page #{k + 1}\n\n#{lorem(4)}")
    page.save!
    (k % 4).times do |v|
      content = page.reload.content
      content.text = "#{content.text}\n\nh2. Révision #{v + 2}\n\n#{lorem(2)}"
      content.author = pick(PEOPLE)
      content.comments = "Révision #{v + 2}"
      content.save!
    end
    file!(page, pick(PEOPLE), "annexe-#{k + 1}.txt", "Annexe #{k + 1}\n#{lorem(2)}\n") if k % 3 == 0
    parent = page if k % 5 == 4
  end
end

# 4. News, documents and saved queries.
section("News, documents, queries", -> { PROJECT.news.where(title: "Volume : annonce 1").exists? }) do
  root = PROJECT.wiki.find_page("Volume_Wiki")
  root.content.update!(text: root.content.text + "\n\nAnnonces, documents et requêtes du lot Volume.")
  5.times do |k|
    news = News.new(project: PROJECT, author: pick(PEOPLE), title: "Volume : annonce #{k + 1}", summary: lorem(1)[0, 200], description: lorem(5))
    news.save!
    news.update_columns(created_on: Time.utc(2026, 4, 1 + k, 9))
    (k % 3).times { |c| Comment.create!(commented: news, author: pick(PEOPLE), comments: "Commentaire #{c + 1} : #{lorem(1)}") }
  end
  categories = DocumentCategory.all.to_a
  5.times do |k|
    document = PROJECT.documents.create!(category: categories[k % categories.size], title: "Volume : document #{k + 1}", description: lorem(3))
    file!(document, pick(PEOPLE), "volume-document-#{k + 1}.txt", "Document #{k + 1}\n#{lorem(3)}\n")
  end
  f = ->(operator, *values) { { operator: operator, values: values } }
  20.times do |k|
    query = IssueQuery.new(name: "Volume : requête #{k + 1}")
    query.project = PROJECT
    query.user = pick(PEOPLE)
    query.visibility = [Query::VISIBILITY_PUBLIC, Query::VISIBILITY_PRIVATE, Query::VISIBILITY_PUBLIC][k % 3]
    query.filters = [{ "status_id" => f.("o", "") }, { "tracker_id" => f.("=", trackers.first.to_s) }, { "priority_id" => f.("=", "6") },
      { "assigned_to_id" => f.("=", "me") }, { "subject" => f.("~", "Volume") }][k % 5]
    query.column_names = [:tracker, :status, :subject, :assigned_to, :updated_on].first(3 + k % 3)
    query.sort_criteria = [["id", "desc"]]
    query.save!(validate: false)
  end
end

puts "Totals: #{PROJECT.issues.count} issues, #{Journal.where(journalized: PROJECT.issues).count} journals, " \
  "#{TimeEntry.where(project_id: PROJECT.id).count} time entries, #{PROJECT.wiki.pages.count} wiki pages, #{PROJECT.news.count} news, " \
  "#{PROJECT.documents.count} documents, #{Query.where(project_id: PROJECT.id).count} queries, " \
  "#{Attachment.where(container: PROJECT.issues).count} issue files; missing files: " \
  "#{Attachment.where('created_on > ?', STARTED - 60).to_a.reject { |row| File.exist?(row.diskfile) }.size}"
