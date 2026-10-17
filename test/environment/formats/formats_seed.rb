# frozen_string_literal: true
# File: redmine_mirror/test/environment/formats/formats_seed.rb
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
# Source projects in Textile, Markdown and CKEditor HTML (redmine_per_project_formatting),
# with the text constructs, images and references that a format conversion must handle.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
abort "Source instance only" unless ENV["MIRROR_ROLE"] == "source"
exit if Project.exists?(identifier: "mirror-format-textile")

admin = User.find_by!(login: "admin")
alice = User.find_by!(login: "alice")
User.current = admin
manager = Role.find_by!(name: "Manager")
tracker = Tracker.find_by!(name: "Feature")
status = IssueStatus.find_by!(name: "New")
priority = IssuePriority.default
long_text = IssueCustomField.find_or_create_by!(name: "Mirror formatted notes") do |field|
  field.field_format = "text"
  field.text_formatting = "full"
  field.is_for_all = true
  field.trackers = Tracker.all
end
reference = Project.find_by!(identifier: "mirror-demo").issues.order(:id).first

png = lambda do |name, color|
  path = "/tmp/#{name}"
  system("convert", "-size", "24x16", "xc:#{color}", path, exception: true)
  path
end

create_project = lambda do |identifier, name, format|
  project = Project.create!(name: name, identifier: identifier, is_public: false,
    enabled_module_names: %w[issue_tracking time_tracking])
  project.update_columns(text_formatting: format, modules_for_formatting: nil)
  project.trackers = Tracker.all
  Member.create!(project: project, user: alice, roles: [manager])
  project
end

# Attach a file through the native model so texts can reference it by name and URL.
create_issue = lambda do |project, subject, description, attachment: nil, notes: [], formatted: nil|
  issue = Issue.new(project: project, tracker: tracker, status: status, priority: priority,
    author: alice, subject: subject, description: description)
  issue.custom_field_values = {long_text.id => formatted} if formatted
  if attachment
    issue.save!
    issue.attachments.create!(file: File.open(attachment, "rb"), filename: File.basename(attachment),
      author: alice, content_type: "image/png")
  end
  issue.save!
  # init_journal keeps an already initialized journal: load the issue again for each note.
  notes.each do |text|
    note_issue = Issue.find(issue.id)
    note_issue.init_journal(alice, text)
    note_issue.save!
  end
  issue.reload
end

# ---- Textile ----
textile = create_project.call("mirror-format-textile", "Mirror format Textile", "textile")
textile_issue = create_issue.call(textile, "Textile constructs", <<~TEXTILE, attachment: png.call("textile-red.png", "red"),
  h2. Release notes

  *Bold*, _italic_, -strike-, +inserted+, ^sup^ and ~sub~ with ACRONYMS kept as is.
  Inline @code with @ inside@ and an email: support@example.com.

  * first item
  ** nested item
  # numbered

  |_. Key |_. Value |
  | cpu | 4 |

  bq. A quoted line.

  <pre>
  raw <b>tags</b> stay literal
  </pre>

  bc. code block line

  <notextile>*not bold*</notextile>, <b>inline html</b>, -[[Wiki page]]- and {{toc}}.

  Image by name: !textile-red.png!
  "A link":https://www.redmine.org and attachment:textile-red.png
  Same project: #ISSUE, other project: ##{reference.id}, URL: http://source:3000/issues/#{reference.id}
TEXTILE
  notes: ["Note with *bold* and @code@ and a reference ##{reference.id}.", "p(. Indented paragraph"],
  formatted: "Custom field with *bold* and _italic_")
textile_issue.update_column(:description, textile_issue.description.sub("#ISSUE", "##{textile_issue.id}"))
attachment = textile_issue.attachments.first
textile_issue.update_column(:description, textile_issue.description + "\nAttachment URL: !/attachments/download/#{attachment.id}/textile-red.png!\n")

# ---- Markdown ----
markdown = create_project.call("mirror-format-markdown", "Mirror format Markdown", "markdown")
create_issue.call(markdown, "Markdown constructs", <<~MARKDOWN, attachment: png.call("markdown-blue.png", "blue"),
  ## Release notes

  **Bold**, *italic*, ~~strike~~ and `inline code` with an email: support@example.com.

  - first item
    - nested item
  1. numbered

  | Key | Value |
  |-----|-------|
  | cpu | 4 |

  > A quoted line.

  ```ruby
  puts "fenced"
  ```

  Image by name: ![blue](markdown-blue.png)
  [A link](https://www.redmine.org), [[Wiki page]], {{toc}} and ##{reference.id}.
MARKDOWN
  notes: ["Note with **bold** and `code`."], formatted: "Custom field with **bold**")

# ---- CKEditor HTML, with Rich images and a text written before the switch ----
html = create_project.call("mirror-format-html", "Mirror format CKEditor", "CKEditor")
rich = Rich::RichFile.new(simplified_type: "image")
rich.rich_file = File.open(png.call("rich-green.png", "green"), "rb")
rich.save!
rich_url = rich.rich_file.url(:original, false)
create_issue.call(html, "CKEditor constructs", <<~HTML,
  <h2>Release notes</h2>
  <p><strong>Bold</strong>, <em>italic</em>, <s>strike</s> and <code>code</code>.</p>
  <ul><li>first item</li></ul>
  <table><tbody><tr><th>Key</th><th>Value</th></tr><tr><td>cpu</td><td>4</td></tr></tbody></table>
  <blockquote><p>A quoted line.</p></blockquote>
  <p>Rich image: <img alt="" src="#{rich_url}" /></p>
  <p>Absolute Rich image: <img alt="" src="http://source:3000#{rich_url}" /></p>
  <p>Reference ##{reference.id} and <a href="http://source:3000/issues/#{reference.id}">its URL</a>.</p>
HTML
  notes: ["<p>Note with <strong>bold</strong> and a Rich thumbnail <img src=\"#{rich.rich_file.url(:rich_thumb, false)}\" /></p>"],
  formatted: "<p>Custom field in <em>HTML</em></p>")
create_issue.call(html, "Written before the switch to CKEditor", "h3. Old Textile text\n\n*Still Textile* in an HTML project.",
  notes: ["Old *Textile* note", "<p>New <strong>HTML</strong> note</p>"])

puts "Seeded format projects: Textile ##{textile.id}, Markdown ##{markdown.id}, CKEditor ##{html.id}; Rich #{rich_url}"
