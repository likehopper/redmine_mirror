# frozen_string_literal: true
# File: redmine_mirror/test/fixtures/mirror_demo/generate.rb
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
# Generate the demo source project: the answers a Redmine 4 source with Mirror source,
# Redmine Tags and Scrum gives the reader account Mirror uses. Each issue is one case,
# named in its subject. Deterministic: run it again after a change and commit the result.
#   ruby test/fixtures/mirror_demo/generate.rb

require "base64"
require "date"
require "digest"
require "erb"
require "fileutils"
require "json"
require "uri"
require "zlib"

OUT = __dir__
SOURCE = "https://source.example"

# Redmine's default data, plus two values per list to map.
STATUSES = [[1, "New", false], [2, "In Progress", false], [3, "Resolved", false], [4, "Feedback", false],
  [5, "Closed", true], [6, "Rejected", true], [7, "In review", false], [8, "On hold", false]].freeze
TRACKERS = [[1, "Bug"], [2, "Feature"], [3, "Support"], [4, "Task"], [5, "Epic"]].freeze
PRIORITIES = [[1, "Low"], [2, "Normal"], [3, "High"], [4, "Urgent"], [5, "Immediate"]].freeze
DOCUMENT_CATEGORIES = [[6, "User documentation"], [7, "Technical documentation"], [12, "Meeting minutes"], [13, "Specifications"]].freeze
ACTIVITIES = [[8, "Design"], [9, "Development"], [10, "Testing"], [11, "Project management"]].freeze
ROLES = { manager: [3, "Manager"], developer: [4, "Developer"], reporter: [5, "Reporter"], reader: [6, "Mirror reader"],
  client: [7, "Client"] }.freeze
USERS = { john: [5, "John Doe"], alice: [6, "Alice Client"], bob: [7, "Bob Former"], tom: [8, "Tom Developer"],
  paula: [9, "Paula Pilot"], reader: [10, "Mirror Reader"] }.freeze
PROJECT = { "id" => 1, "name" => "Demo shop" }.freeze
PARTNER = { "id" => 2, "name" => "Partner portal" }.freeze
CATEGORIES = { front: { "id" => 1, "name" => "Front office" }, back: { "id" => 2, "name" => "Back office" },
  api: { "id" => 3, "name" => "API" }, partner: { "id" => 4, "name" => "Partner API" } }.freeze
VERSIONS = [
  { "id" => 1, "project" => PROJECT, "name" => "Release 1.0", "description" => "First public release", "status" => "open",
    "due_date" => "2026-12-15", "sharing" => "none" },
  { "id" => 2, "project" => PROJECT, "name" => "Beta 0.9", "description" => "Beta, released", "status" => "closed",
    "due_date" => "2026-09-30", "sharing" => "none" },
  { "id" => 3, "project" => PROJECT, "name" => "Alpha 0.8", "description" => "Locked: no new issue", "status" => "locked",
    "due_date" => "2026-08-31", "sharing" => "none" },
  { "id" => 4, "project" => PARTNER, "name" => "Shared roadmap", "description" => "Shared by the partner portal with every project",
    "status" => "open", "due_date" => "2027-03-31", "sharing" => "system" }
].freeze
SEVERITY = { "id" => 1, "name" => "Severity" }.freeze
CUSTOMER_REFERENCE = { "id" => 2, "name" => "Customer reference" }.freeze

LOREM = ["Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
  "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
  "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.",
  "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."].freeze

def lorem(count, offset = 0)
  Array.new(count) { |index| LOREM[(index + offset) % LOREM.size] }.join(" ")
end

def time(day, hour = 9, minute = 0)
  (Time.utc(2026, 9, 1) + (day - 1) * 86_400 + hour * 3600 + minute * 60).strftime("%Y-%m-%dT%H:%M:%SZ")
end

def ref(table, key)
  id, name = table.is_a?(Hash) ? table.fetch(key) : table.find { |row| row.first == key }
  { "id" => id, "name" => name }
end

def user(key)
  ref(USERS, key)
end

# ---------------------------------------------------------------------------------------
# Files: small real files, written once and shared by the attachments that use them.

def zip(entries)
  out = "".b
  central = "".b
  entries.each do |name, data|
    data = data.b
    name = name.b
    crc = Zlib.crc32(data)
    offset = out.bytesize
    out << [0x04034b50, 20, 0, 0, 0, 0x21, crc, data.bytesize, data.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") << name << data
    central << [0x02014b50, 20, 20, 0, 0, 0, 0x21, crc, data.bytesize, data.bytesize, name.bytesize, 0, 0, 0, 0, 0, offset]
      .pack("VvvvvvvVVVvvvvvVV") << name
  end
  start = out.bytesize
  out << central << [0x06054b50, 0, 0, entries.size, entries.size, central.bytesize, start, 0].pack("VvvvvVVv")
end

def pdf(title)
  stream = "BT /F1 18 Tf 72 720 Td (#{title}) Tj ET"
  objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
  out = +"%PDF-1.4\n"
  offsets = objects.each_with_index.map do |object, index|
    offset = out.bytesize
    out << "#{index + 1} 0 obj\n#{object}\nendobj\n"
    offset
  end
  xref = out.bytesize
  out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n" << offsets.map { |offset| format("%010d 00000 n \n", offset) }.join
  out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
end

RELS = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' \
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/%s" Target="%s"/></Relationships>'
TYPES = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' \
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>%s</Types>'

def docx(text)
  zip("[Content_Types].xml" => format(TYPES, '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'),
    "_rels/.rels" => format(RELS, "officeDocument", "word/document.xml"),
    "word/document.xml" => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' \
      "<w:body><w:p><w:r><w:t>#{text}</w:t></w:r></w:p></w:body></w:document>")
end

def xlsx(rows)
  cells = rows.each_with_index.map do |row, line|
    "<row r=\"#{line + 1}\">" + row.each_with_index.map { |value, column| "<c r=\"#{('A'.ord + column).chr}#{line + 1}\" t=\"inlineStr\"><is><t>#{value}</t></is></c>" }.join + "</row>"
  end.join
  main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  zip("[Content_Types].xml" => format(TYPES, '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' \
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'),
    "_rels/.rels" => format(RELS, "officeDocument", "xl/workbook.xml"),
    "xl/workbook.xml" => "<workbook xmlns=\"#{main}\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Tests\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
    "xl/_rels/workbook.xml.rels" => format(RELS, "worksheet", "worksheets/sheet1.xml"),
    "xl/worksheets/sheet1.xml" => "<worksheet xmlns=\"#{main}\"><sheetData>#{cells}</sheetData></worksheet>")
end

PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAADAAAAAgCAMAAABjCgsuAAAACVBMVEU9erjywU7///+FTTK/AAAAIElEQVQ4y2NgGAVEA0Z0ABRjQgejGkY1jGoYvhpGFgAAYDsEMKM2A6MAAAAASUVORK5CYII=")
JPEG = Base64.decode64("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAeACgDASIAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAAAAEE/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/EABcBAQEBAQAAAAAAAAAAAAAAAAAEAgX/xAAVEQEBAAAAAAAAAAAAAAAAAAAAE//aAAwDAQACEQMRAD8A1Cii7c0FC5NBQuTUUca6+aChcmgoXJv/2Q==")
GIF = Base64.decode64("R0lGODlhEAAQAPAAAMwzMwAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQAMgAAACwAAAAAEAAQAAACDoSPqcvtD6OctNqLsz4FACH5BAAyAAAALAAAAAAQABAAgDPMMwAAAAIOhI+py+0Po5y02ouzPgUAOw==")
SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="32"><rect width="48" height="32" fill="#3d7ab8"/>' \
  '<circle cx="24" cy="16" r="10" fill="#f2c14e"/></svg>'

# name => [content type, bytes or a size (generated by the replay)]
ASSETS = {
  "diagram.png" => ["image/png", PNG],
  "screenshot.jpg" => ["image/jpeg", JPEG],
  "steps.gif" => ["image/gif", GIF],
  "logo.svg" => ["image/svg+xml", SVG],
  "specification.pdf" => ["application/pdf", pdf("Demo shop - functional specification")],
  "quote.pdf" => ["application/pdf", pdf("Demo shop - quote v2")],
  "minutes.docx" => ["application/vnd.openxmlformats-officedocument.wordprocessingml.document", docx("Steering committee minutes: version 1.0 confirmed for December.")],
  "test-plan.xlsx" => ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", xlsx([%w[Step Expected Result], ["Open the cart", "Cart shown", "OK"], ["Pay", "Receipt sent", "KO"]])],
  "deliverables.zip" => ["application/zip", zip("README.txt" => "Deliverables of version 1.0\n", "CHANGES.txt" => "- Cart\n- Payment\n")],
  "settings.json" => ["application/json", JSON.pretty_generate("shop" => { "currency" => "EUR", "tax_rate" => 0.2 }) + "\n"],
  "orders.csv" => ["text/csv", "order,customer,total\n1001,Alice Client,42.50\n1002,Paula Pilot,13.00\n"],
  "draft.csv" => ["text/csv", "order,total\n1001,40.00\n"],
  "release-plan.txt" => ["text/plain", "Version 1.0: December 15\n"],
  "release-notes.txt" => ["text/plain", "1.0: cart, payment, PDF invoices\n"],
  "photo.jpg" => ["image/jpeg", 1_250_000],
  "database-dump.sql" => ["application/sql", 5 * 1024 * 1024]
}.freeze

@attachment_id = 0
@downloads = {}

def attachment(asset, author:, at:, filename: asset, description: nil, mirror_source: false)
  type, content = ASSETS.fetch(asset)
  @attachment_id += 1
  id = @attachment_id
  @downloads[mirror_source ? "mirror/source/attachments/#{id}/download" : "attachments/download/#{id}"] =
    content.is_a?(Integer) ? { "size" => content } : { "file" => asset }
  file = { "id" => id, "filename" => filename, "filesize" => content.is_a?(Integer) ? content : content.bytesize, "content_type" => type,
    "description" => description, "content_url" => "#{SOURCE}/attachments/download/#{id}/#{ERB::Util.url_encode(filename)}" }
  file["thumbnail_url"] = "#{SOURCE}/attachments/thumbnail/#{id}" if type.match?(%r{\Aimage/(png|jpeg|gif)\z})
  file.merge("author" => user(author), "created_on" => at)
end

def digest(asset)
  content = ASSETS.fetch(asset).last
  Digest::SHA256.hexdigest(content.is_a?(Integer) ? "" : content)
end

# ---------------------------------------------------------------------------------------
# Issues: one case each, its subject says which.

@issues = []
@journal_id = 0
@relation_id = 0

def issue(subject, tracker:, author: :john, assignee: nil, status: 1, priority: 2, category: nil, version: nil, parent: nil,
  is_private: false, description: "", start_date: nil, due_date: nil, estimated: nil, done: 0, severity: nil, customer: nil,
  day: @issues.size + 1, project: PROJECT)
  record = { "id" => project == PROJECT ? @issues.count { |row| row.dig("project", "id") == 1 } + 1 : 900 + @issues.size,
    "project" => project, "tracker" => ref(TRACKERS, tracker), "status" => ref(STATUSES.map { |row| row.first(2) }, status),
    "priority" => ref(PRIORITIES, priority), "author" => user(author) }
  record["assigned_to"] = user(assignee) if assignee
  record["category"] = CATEGORIES.fetch(category) if category
  record["fixed_version"] = VERSIONS.find { |row| row["id"] == version }.slice("id", "name") if version
  record["parent"] = { "id" => parent } if parent
  record.merge!("subject" => subject, "description" => description.gsub(/\r?\n/, "\r\n"), "start_date" => start_date, "due_date" => due_date,
    "done_ratio" => done, "is_private" => is_private, "estimated_hours" => estimated)
  if [1, 3].include?(tracker)
    record["custom_fields"] = [SEVERITY.merge("value" => severity), CUSTOMER_REFERENCE.merge("value" => customer)]
  end
  record.merge!("created_on" => time(day), "journals" => [], "attachments" => [], "relations" => [], "watchers" => [])
  @issues << record
  yield record if block_given?
  record
end

def note(issue, author, at, notes = "", is_private: false, details: [])
  @journal_id += 1
  issue["journals"] << { "id" => @journal_id, "user" => user(author), "notes" => notes.gsub(/\r?\n/, "\r\n"), "created_on" => at,
    "private_notes" => is_private, "details" => details }
end

def change(name, old, new)
  { "property" => "attr", "name" => name, "old_value" => old&.to_s, "new_value" => new&.to_s }
end

def attach(issue, asset, author:, at:, **options)
  file = attachment(asset, author: author, at: at, **options)
  issue["attachments"] << file
  file
end

REVERSE = { "relates" => "relates", "duplicates" => "duplicated", "blocks" => "blocked", "precedes" => "follows",
  "copied_to" => "copied_from" }.freeze

def relate(from, type, to, delay: nil, at: nil, author: :john)
  @relation_id += 1
  relation = { "id" => @relation_id, "issue_id" => from["id"], "issue_to_id" => to["id"], "relation_type" => type, "delay" => delay }
  [from, to].each { |issue| issue["relations"] << relation if issue.dig("project", "id") == 1 }
  return unless at
  note(from, author, at, details: [{ "property" => "relation", "name" => type, "old_value" => nil, "new_value" => to["id"].to_s }])
  note(to, author, at, details: [{ "property" => "relation", "name" => REVERSE.fetch(type), "old_value" => nil, "new_value" => from["id"].to_s }]) if to.dig("project", "id") == 1
end

def watch(issue, *users)
  issue["watchers"].concat(users.map { |key| user(key) })
end

TEXTILE = <<~TEXTILE
  h2. Comparison table

  The product page compares the three plans. Tom drafts it, Alice checks the wording.

  * *bold*, _italic_, -struck-, +inserted+ and @inline code@
  * a "link to Redmine":https://www.redmine.org and a bare URL https://www.redmine.org
  # first numbered item
  # second numbered item

  |_. Plan |_. Price |_. Support |
  | Basic | 10 EUR | e-mail |
  | Pro | 25 EUR | phone |

  bq. Keep the table short: three plans, three columns.

  <pre><code class="ruby">
  plans.each { |plan| puts plan.name }
  </code></pre>
TEXTILE

# [Text]
issue("[Text] Textile: headings, lists, tables, code and links", tracker: 2, assignee: :tom, status: 2, category: :front, version: 1,
  description: TEXTILE) do |issue|
  note(issue, :tom, time(3, 10), "First draft online, see the table above.", details: [change("status_id", 1, 2)])
  note(issue, :alice, time(4, 14), "Wording is fine. Can we make *Pro* stand out?")
end
issue("[Text] Markdown written in a Textile project", tracker: 4, author: :tom, assignee: :tom, description: <<~MARKDOWN) do |issue|
  # Checkout steps

  Tom pasted these notes from his **Markdown** editor into a Textile project.

  - add to cart
  - pay with a [test card](https://www.redmine.org)

  ```
  checkout --dry-run
  ```
MARKDOWN
  note(issue, :alice, time(5, 11), "The source shows the raw Markdown: Mirror detects it and converts it as Markdown.")
end
issue("[Text] Plain text, no markup", tracker: 3, author: :alice, assignee: :john,
  description: "Hello,\nThe invoice of order 1001 is missing.\nCould you send it again?\nThanks, Alice") do |issue|
  note(issue, :john, time(6, 9), "Sent again by e-mail.")
end
issue("[Text] Empty description", tracker: 4, assignee: :tom, description: "")
issue(("[Text] Long subject with special characters <script>alert('x')</script> & \"quotes\" € œ - " + "long subject " * 20)[0, 255],
  tracker: 1, author: :alice, severity: "Minor", description: "The subject has 255 characters, HTML that must stay text, quotes and symbols.")
issue("[Text] Accented characters: é è à ç ü ß ñ", tracker: 1, author: :alice, assignee: :tom, severity: "Minor",
  description: "The shop header shows \"CafÃ©\" instead of \"Café\".\n\nOther samples: crème brûlée, Größe, niño, garçon, à bientôt.") do |issue|
  note(issue, :tom, time(7, 15), "Fixed the page encoding: « Café » is back.", details: [change("status_id", 1, 3)])
  issue["status"] = ref(STATUSES.map { |row| row.first(2) }, 3)
end
issue("[Text] Emoji in the description, not in the subject", tracker: 2, author: :paula,
  description: "Release party checklist 🎉\n\n* cake 🍰\n* music 🎵\n* deploy ✅\n\nRedmine 4 on MySQL stores subjects in 3-byte UTF-8: no emoji there.")
issue("[Text] Very long description (lorem ipsum, about 60 KB)", tracker: 4, author: :tom,
  description: Array.new(140) { |index| "h3. Part #{index + 1}\n\n#{lorem(4, index)}" }.join("\n\n"))
issue("[Text] References to issues, notes, wiki pages, versions, files and the source", tracker: 2, author: :john, assignee: :tom, version: 1,
  description: <<~TEXTILE) do |issue|
  This issue gathers every kind of reference Mirror rewrites:

  * issues #1 and #3, a note #1#note-1
  * wiki pages [[Home]], [[Installation_guide|the installation guide]] and [[Café_menu]]
  * version version:"Release 1.0", document document#1, news news#1
  * attachment attachment:"diagram.png" of this issue
  * a commit commit:abc1234 (the source has no repository)
  * an absolute link to the source: #{SOURCE}/issues/2
TEXTILE
  attach(issue, "diagram.png", author: :john, at: time(9, 9, 5))
end
issue("[Text] Inline images: inline, aligned, sized and in a table", tracker: 2, author: :john, category: :front,
  description: <<~TEXTILE) do |issue|
  Inline: !diagram.png!

  Right aligned: !>screenshot.jpg!

  Sized: !{width: 50%}diagram.png!

  |!screenshot.jpg!|Screenshot in a table cell|
TEXTILE
  attach(issue, "diagram.png", author: :john, at: time(10, 9, 5))
  attach(issue, "screenshot.jpg", author: :john, at: time(10, 9, 5), description: "Home page")
end
issue("[Text] Image shown only in a note", tracker: 1, author: :alice, assignee: :tom, severity: "Major",
  description: "The payment button disappears on small screens. Screenshot in the first note.") do |issue|
  file = attach(issue, "screenshot.jpg", author: :alice, at: time(11, 10))
  note(issue, :alice, time(11, 10), "Here it is:\n\n!screenshot.jpg!",
    details: [{ "property" => "attachment", "name" => file["id"].to_s, "old_value" => nil, "new_value" => "screenshot.jpg" }])
end

# [Files]
issue("[Files] One attachment of each kind: images, PDF, office, archive, data", tracker: 4, author: :john, assignee: :alice,
  description: "Alice collects the version 1.0 files here before the review.") do |issue|
  %w[diagram.png screenshot.jpg steps.gif logo.svg specification.pdf minutes.docx test-plan.xlsx deliverables.zip settings.json orders.csv
    release-plan.txt photo.jpg].each_with_index { |asset, index| attach(issue, asset, author: index.even? ? :john : :alice, at: time(12, 9, index)) }
  watch(issue, :john, :alice)
end
issue("[Files] Large attachment (5 MB)", tracker: 3, author: :tom, assignee: :john,
  description: "Tom attached the database dump the support team asked for.") do |issue|
  attach(issue, "database-dump.sql", author: :tom, at: time(13, 16), description: "Anonymized dump")
end
issue("[Files] File names with spaces, accents and parentheses", tracker: 4, author: :alice,
  description: "The files keep their names, whatever the characters.") do |issue|
  attach(issue, "quote.pdf", author: :alice, at: time(14, 9), filename: "Quote (v2) 2026.pdf")
  attach(issue, "minutes.docx", author: :alice, at: time(14, 9), filename: "meeting notes - café.docx")
  attach(issue, "diagram.png", author: :alice, at: time(14, 9), filename: "UPPER-CASE.PNG")
end
issue("[Files] Attachment added then removed: the history keeps both", tracker: 4, author: :tom, assignee: :tom,
  description: "Tom attached a draft export, then replaced it with the final one.") do |issue|
  draft_id = 999 # a deleted attachment: its ID remains in the history only
  note(issue, :tom, time(15, 10), "Draft export attached.",
    details: [{ "property" => "attachment", "name" => draft_id.to_s, "old_value" => nil, "new_value" => "draft.csv" }])
  final = attach(issue, "orders.csv", author: :tom, at: time(16, 11))
  note(issue, :tom, time(16, 11), "Final export attached, draft removed.",
    details: [{ "property" => "attachment", "name" => final["id"].to_s, "old_value" => nil, "new_value" => "orders.csv" },
      { "property" => "attachment", "name" => draft_id.to_s, "old_value" => "draft.csv", "new_value" => nil }])
end
issue("[Files] Same file name uploaded twice", tracker: 1, author: :alice, severity: "Minor",
  description: "Alice uploaded a new screenshot with the same name after the fix.") do |issue|
  attach(issue, "screenshot.jpg", author: :alice, at: time(17, 9), description: "Before")
  second = attach(issue, "screenshot.jpg", author: :alice, at: time(18, 9), description: "After")
  note(issue, :alice, time(18, 9), "New screenshot, same name.",
    details: [{ "property" => "attachment", "name" => second["id"].to_s, "old_value" => nil, "new_value" => "screenshot.jpg" }])
end

# [State]
issue("[State] Private issue", tracker: 1, author: :alice, assignee: :john, is_private: true, priority: 4, severity: "Critical",
  description: "A customer can see another customer's orders by changing the URL. Private until fixed.") do |issue|
  note(issue, :john, time(19, 10), "Confirmed. Fix planned for 1.0.")
  watch(issue, :john, :alice)
end
issue("[State] Closed in a closed version", tracker: 2, assignee: :tom, status: 5, version: 2, done: 100,
  description: "Newsletter sign-up, shipped with the beta.") do |issue|
  note(issue, :tom, time(20, 17), "Shipped in 0.9.", details: [change("status_id", 1, 5), change("done_ratio", 0, 100)])
  issue["closed_on"] = time(20, 17)
end
issue("[State] In a locked version", tracker: 4, assignee: :tom, version: 3,
  description: "Planned for 0.8, which is now locked: the issue stays there.")
issue("[State] In a version shared by another project", tracker: 2, author: :paula, version: 4,
  description: "The partner portal shares its roadmap with every project. Mirror imports the shared version first.")
issue("[State] Rejected", tracker: 1, author: :alice, assignee: :john, status: 6, severity: "Minor",
  description: "Prices should show four decimals.") do |issue|
  note(issue, :john, time(23, 9), "Rejected: prices keep two decimals, as the law requires.", details: [change("status_id", 1, 6)])
  issue["closed_on"] = time(23, 9)
end
issue("[State] Reopened after closing", tracker: 1, author: :alice, assignee: :tom, status: 2, severity: "Major",
  description: "The cart empties itself after one hour.") do |issue|
  note(issue, :tom, time(24, 10), "Session lifetime raised.", details: [change("status_id", 1, 3)])
  note(issue, :john, time(25, 9), "Closing after the review.", details: [change("status_id", 3, 5)])
  note(issue, :alice, time(26, 11), "Still happens on mobile, reopening.", details: [change("status_id", 5, 4)])
  note(issue, :tom, time(26, 15), "Looking at the mobile session cookie.", details: [change("status_id", 4, 2)])
  issue["closed_on"] = time(25, 9)
end
issue("[State] Moved from another project", tracker: 3, author: :paula, assignee: :john,
  description: "Opened by mistake in the partner portal, then moved here.") do |issue|
  note(issue, :john, time(27, 9), "Moved to the demo shop.", details: [change("project_id", 2, 1)])
end
issue("[State] Category of another project", tracker: 4, author: :john, category: :partner,
  description: "Its category belongs to the partner portal: the destination must create or map it.")
issue("[State] Assigned to a user who left", tracker: 4, author: :john, assignee: :bob,
  description: "Bob left the team; his account is locked. The issue is still his.")
issue("[State] Written by a user who left", tracker: 1, author: :bob, assignee: :tom, severity: "Major",
  description: "Bob wrote this before leaving: the search ignores accents.")
issue("[State] Unassigned, no category, no version", tracker: 3, author: :alice, description: "Nothing but a subject and this text.")
issue("[State] Dates, estimate and progress", tracker: 2, assignee: :tom, status: 2, start_date: "2026-10-01", due_date: "2026-10-20",
  estimated: 12.5, done: 60, category: :back, version: 1, description: "PDF invoices: twelve and a half hours estimated, 60% done.") do |issue|
  note(issue, :tom, time(29, 17), "Template done.", details: [change("done_ratio", 30, 60)])
end
issue("[State] Custom fields: severity and customer reference", tracker: 1, author: :alice, severity: "Major", customer: "PO-2026-118",
  description: "The order confirmation e-mail has no order number.")
issue("[State] Extra tracker and status: Epic, On hold", tracker: 5, status: 8, author: :paula,
  description: "Marketplace for third-party sellers: on hold until next year.")
issue("[State] Extra status In review, priority Immediate", tracker: 4, status: 7, priority: 5, assignee: :john, author: :tom, category: :api,
  description: "Payment provider upgrade, waiting for John's review.")

# [History]
issue("[History] Every field changed: subject, description, status, priority, assignee, version, category, dates, estimate",
  tracker: 2, assignee: :tom, status: 2, priority: 3, category: :back, version: 1, start_date: "2026-10-05", due_date: "2026-10-30",
  estimated: 8.0, description: "Export orders as CSV, with the customer and the total.") do |issue|
  note(issue, :paula, time(33, 9), "Clearer subject and description.",
    details: [change("subject", "Export", issue["subject"]), change("description", "Export orders.", issue["description"])])
  note(issue, :john, time(33, 11), "Planned for 1.0, Tom takes it.",
    details: [change("fixed_version_id", 2, 1), change("assigned_to_id", 6, 8), change("category_id", 1, 2), change("priority_id", 2, 3)])
  note(issue, :tom, time(34, 9), "Started.", details: [change("status_id", 1, 2), change("start_date", nil, "2026-10-05"),
    change("due_date", "2026-10-20", "2026-10-30"), change("estimated_hours", "5.0", "8.0")])
end
issue("[History] Private notes", tracker: 1, author: :alice, assignee: :john, severity: "Minor",
  description: "The delivery fee is wrong for islands.") do |issue|
  note(issue, :john, time(35, 9), "Reproduced on the test shop.")
  note(issue, :john, time(35, 10), "Internal: the carrier changed its rates without telling us.", is_private: true)
  note(issue, :tom, time(35, 14), "Internal: fixed in the rate table.", is_private: true)
  note(issue, :john, time(36, 9), "Fixed, thank you Alice.")
end
issue("[History] 100 notes in one issue", tracker: 3, author: :alice, assignee: :john,
  description: "A long support thread about a refund.") do |issue|
  100.times do |index|
    note(issue, [:alice, :john, :paula, :tom][index % 4], time(37 + index / 10, 8 + index % 10), "Reply #{index + 1}. #{lorem(1, index)}")
  end
end
issue("[History] Note by a user who left", tracker: 4, author: :john, assignee: :tom,
  description: "Bob documented the legacy import before leaving.") do |issue|
  note(issue, :bob, time(38, 16), "The legacy import runs at night, from the ERP export. Ask the ERP team for access.")
end
issue("[History] Note quoting another note, with a code block", tracker: 1, author: :tom, assignee: :tom, severity: "Minor",
  description: "The stock counter goes negative.") do |issue|
  note(issue, :alice, time(39, 9), "It happens when two customers buy the last item.")
  note(issue, :tom, time(39, 11), "Alice wrote:\nbq. It happens when two customers buy the last item.\n\nA lock fixes it:\n\n<pre>stock.with_lock { stock.decrement! }</pre>")
end

# [Tree]
root = issue("[Tree] Three levels: root", tracker: 5, author: :paula, description: "Customer accounts.")
middle = issue("[Tree] Three levels: middle", tracker: 2, parent: root["id"], description: "Sign-up and sign-in.")
issue("[Tree] Three levels: leaf", tracker: 4, assignee: :tom, parent: middle["id"], description: "Password reset e-mail.")
early = issue("[Tree] Subtask created before its parent", tracker: 4, assignee: :tom, parent: @issues.size + 2,
  description: "Created first; its parent was created the day after.")
late = issue("[Tree] Parent created after its subtask", tracker: 2, description: "Created after its subtask, which then moved under it.") do |issue|
  note(early, :john, time(42, 9), "Moved under its new parent.", details: [change("parent_id", nil, issue["id"])])
end
issue("[Tree] Parent changed in the history", tracker: 4, parent: root["id"], description: "First under the late parent, then under the root.") do |issue|
  note(issue, :john, time(43, 10), "Belongs to customer accounts.", details: [change("parent_id", late["id"], root["id"])])
end

# [Links]
hub = issue("[Links] Every relation type: relates, duplicates, blocks, precedes with a delay, copied to", tracker: 2, assignee: :tom,
  description: "This issue holds one relation of each type, to other cases of this project.")
copy = issue("[Links] Copy of the relation hub", tracker: 2, description: "Copied from the relation hub.")
relate(hub, "relates", @issues[0], at: time(44, 10))
relate(hub, "duplicates", @issues[2], at: time(44, 10))
relate(hub, "blocks", @issues[18], at: time(44, 10))
relate(hub, "precedes", @issues[27], delay: 2, at: time(44, 10))
relate(hub, "copied_to", copy, at: time(45, 9))
partner_issue = issue("Partner issue (not mirrored)", tracker: 1, project: PARTNER, description: "Lives in the partner portal.")
issue("[Links] Related to an issue of another project", tracker: 3, author: :paula,
  description: "Related to an issue of the partner portal, which is not mirrored: the relation waits for it.") do |issue|
  relate(issue, "relates", partner_issue)
end

# [Watch]
issue("[Watch] Watched by four users, one of whom left", tracker: 1, author: :alice, assignee: :tom, severity: "Major",
  description: "Everyone wants to know when the login page works again.") do |issue|
  watch(issue, :john, :alice, :bob, :paula)
end

# [Time]
issue("[Time] Time by several users and activities", tracker: 2, assignee: :tom, version: 1, description: "The cart redesign took the whole team.")
issue("[Time] Time by a user who left", tracker: 4, assignee: :bob, description: "Bob logged time here before leaving.")
issue("[Time] 120 time entries: the list spans two pages", tracker: 4, assignee: :tom, description: "Daily support, a quarter of an hour each day.")

# [Agile]
issue("[Agile] Tags with accents, capitals and spaces", tracker: 2, description: "Tagged \"Front end\", \"café\" and \"URGENT\".")
issue("[Agile] In a sprint, with story points", tracker: 2, assignee: :tom, status: 2, description: "Five story points in Sprint 3.")
issue("[Agile] In a sprint of another project", tracker: 4, description: "Its sprint belongs to the partner portal.")
issue("[Agile] Moved between sprints in the history", tracker: 4, assignee: :tom, description: "Started in Sprint 2, finished in Sprint 3.") do |issue|
  note(issue, :john, time(52, 9), "Moved to the next sprint.", details: [change("sprint_id", 2, 3), change("position", 4, 1)])
end

ISSUES = @issues.select { |row| row.dig("project", "id") == 1 }
by_subject = ->(prefix) { ISSUES.find { |row| row["subject"].start_with?(prefix) } }

# Hierarchy: children as Redmine nests them; last update after the last journal.
@issues.each do |record|
  times = [record["created_on"]] + record["journals"].map { |journal| journal["created_on"] }
  record["updated_on"] = times.max
  record["closed_on"] ||= nil
end
children = lambda do |id|
  ISSUES.select { |row| row.dig("parent", "id") == id }.map do |child|
    entry = { "id" => child["id"], "tracker" => child["tracker"], "subject" => child["subject"] }
    nested = children.call(child["id"])
    nested.empty? ? entry : entry.merge("children" => nested)
  end
end

# ---------------------------------------------------------------------------------------
# Time entries, wiki, documents, news, files, queries, tags, sprints.

@time_entries = []
def spend(issue, author, activity, hours, spent_on, comments)
  entry = { "id" => @time_entries.size + 1, "project" => PROJECT }
  entry["issue"] = { "id" => issue["id"] } if issue
  entry.merge!("user" => user(author), "activity" => ref(ACTIVITIES, activity), "hours" => hours, "comments" => comments,
    "spent_on" => spent_on, "created_on" => "#{spent_on}T17:00:00Z", "updated_on" => "#{spent_on}T17:00:00Z")
  @time_entries << entry
end
spend(ISSUES[0], :tom, 9, 3.0, "2026-09-03", "Table layout")
spend(ISSUES[0], :alice, 10, 0.5, "2026-09-04", "Wording review")
spend(by_subject.("[State] Dates"), :tom, 9, 7.5, "2026-09-29", "Invoice template")
several = by_subject.("[Time] Time by several")
[[:john, 8, 2.0, "Mock-ups"], [:tom, 9, 3.5, "Cart code"], [:alice, 10, 1.0, "Acceptance tests"], [:paula, 11, 0.5, "Planning"]]
  .each_with_index { |(author, activity, hours, comments), index| spend(several, author, activity, hours, "2026-10-#{format('%02d', 10 + index)}", comments) }
spend(by_subject.("[Time] Time by a user who left"), :bob, 9, 4.0, "2026-08-20", "Legacy import notes")
spend(by_subject.("[Time] Time by a user who left"), :bob, 8, 1.5, "2026-08-21", "Handover")
daily = by_subject.("[Time] 120 time entries")
120.times { |index| spend(daily, :tom, 9, 0.25, (Date.new(2026, 6, 1) + index).iso8601, "Support day #{index + 1}") }
3.times { |index| spend(nil, :paula, 11, 1.0, "2026-10-#{format('%02d', 5 + index * 7)}", "Steering meeting (no issue)") }

WIKI = [
  ["Home", nil, ["h1. Home\n\nWiki of the demo shop.", "\n\n* [[Documentation]]\n* [[Meetings_2026]]", "\n\n!diagram.png!"], %w[diagram.png]],
  ["Documentation", "Home", ["h1. Documentation", "\n\n* [[Installation_guide]]\n* [[Architecture]]\n* [[Users'_guide]]\n* [[Café_menu]]"], []],
  ["Installation_guide", "Documentation", ["h1. Installation guide", "\n\n# Download", "\n# Unpack", "\n# Configure", "\n# Migrate the database",
    "\n# Start the server"], %w[deliverables.zip]],
  ["Architecture", "Documentation", ["h1. Architecture\n\nThe shop has a front office, a back office and an API.", "\n\n!diagram.png!\n\nDetails: [[Technical_details]]"],
    %w[diagram.png specification.pdf]],
  ["Technical_details", "Architecture", ["h1. Technical details\n\nThird level of the page tree."], []],
  ["Users'_guide", "Documentation", ["h1. Users' guide\n\nA title with an apostrophe."], []],
  ["Café_menu", "Documentation", ["h1. Café menu\n\nA title with an accent: crème, thé, chocolat."], []],
  ["Meetings_2026", "Home", ["h1. Meetings 2026\n\nThe number in the title is not an ID.", "\n\n* 15 September: steering committee"], %w[minutes.docx]],
  ["Markdown_page", "Home", ["# Markdown page\n\nWritten in **Markdown** in a Textile wiki:\n\n- one\n- two"], []],
  ["Long_page", "Home", ["h1. Long page\n\n" + Array.new(100) { |index| lorem(4, index) }.join("\n\n")], []],
  ["Renamed_page", "Home", ["h1. Old title\n\nCreated as Old_title.", "\n\nRenamed: links to the old title redirect here."], []],
  ["Sandbox", nil, ["h1. Sandbox\n\nA page without a parent."], %w[steps.gif logo.svg test-plan.xlsx]]
].freeze
AUTHORS = %i[john alice tom paula].freeze

@wiki = WIKI.each_with_index.map do |(title, parent, steps, assets), page_index|
  created = time(2 + page_index, 8)
  versions = steps.each_index.map do |index|
    { "title" => title, "parent" => parent && { "title" => parent }, "text" => steps[0..index].join, "version" => index + 1,
      "author" => user(AUTHORS[(page_index + index) % AUTHORS.size]), "comments" => index.zero? ? "" : "Step #{index + 1}",
      "created_on" => created, "updated_on" => time(2 + page_index + index * 3, 9) }.compact
  end
  files = assets.map { |asset| attachment(asset, author: :john, at: created) }
  { "title" => title, "versions" => versions, "attachments" => files }
end

DOCUMENTS = [
  ["Platform architecture", 7, "h2. Overview\n\nFront office, back office and API. See the *diagram*:\n\n!diagram.png!", %w[specification.pdf diagram.png]],
  ["User guide", 6, "", %w[]],
  ["Steering committee minutes, 15 September", 12, "Decisions of the committee: version 1.0 in December.", %w[minutes.docx]],
  ["Functional specifications", 13, "The specifications and the test plan.", %w[specification.pdf test-plan.xlsx]],
  ["Document without files", 6, "Only this description.", %w[]]
].freeze
@documents = DOCUMENTS.each_with_index.map do |(title, category, description, assets), index|
  { "id" => index + 1, "project" => PROJECT, "category" => ref(DOCUMENT_CATEGORIES, category), "title" => title, "description" => description,
    "created_on" => time(3 + index * 5, 10),
    "attachments" => assets.map { |asset| attachment(asset, author: index.even? ? :john : :alice, at: time(3 + index * 5, 10, 1), mirror_source: true) } }
end

NEWS = [
  ["Project kick-off", "The demo shop starts", "h2. Kick-off\n\nThe project starts today:\n\n!diagram.png!\n\nFollowed in #1.", :john,
    [[:alice, "Great news!"], [:bob, "I will be the technical contact."]], %w[diagram.png specification.pdf]],
  ["Version 0.9 released", "", "The beta is online.", :tom, [], []],
  ["Planned maintenance on 12 October", "One hour", "The shop is closed from 6 to 7 a.m.", :paula, [[:bob, "Comment by a user who left."]], []],
  ["News written in Markdown", "Markdown in a Textile project", "## Markdown\n\n**Bold** and a [link](https://www.redmine.org).", :alice, [], %w[screenshot.jpg]]
].freeze
comment_id = 0
@news = NEWS.each_with_index.map do |(title, summary, description, author, comments, assets), index|
  at = time(5 + index * 9, 8)
  { "id" => index + 1, "project" => PROJECT, "author" => user(author), "title" => title, "summary" => summary, "description" => description,
    "created_on" => at,
    "comments" => comments.map.with_index { |(who, content), position| comment_id += 1; { "id" => comment_id, "author" => user(who), "content" => content, "created_on" => time(5 + index * 9, 10 + position), "updated_on" => time(5 + index * 9, 10 + position) } },
    "attachments" => assets.map { |asset| attachment(asset, author: author, at: at, mirror_source: true) } }
end

@files = [["release-plan.txt", nil, "Release plan"], ["deliverables.zip", nil, "Deliverables"], ["release-notes.txt", 1, "Release notes 1.0"],
  ["specification.pdf", 2, "Specification of the beta"]].each_with_index.map do |(asset, version, description), index|
  file = attachment(asset, author: index.odd? ? :alice : :john, at: time(8 + index, 12), description: description)
  file.delete("thumbnail_url")
  file["version"] = VERSIONS.find { |row| row["id"] == version }.slice("id", "name") if version
  file.merge("digest" => digest(asset), "downloads" => index)
end

query = lambda do |id, type, name, visibility, owner, filters, roles: [], columns: [], sort: [], group_by: nil, options: {}|
  { "id" => id, "type" => type, "name" => name, "visibility" => visibility, "project" => PROJECT, "user" => user(owner),
    "roles" => roles.map { |key| ref(ROLES, key) }, "filters" => filters.transform_values { |operator, values| { "operator" => operator, "values" => values } },
    "column_names" => columns, "sort_criteria" => sort, "group_by" => group_by, "options" => options }
end
@queries = [
  query.(1, "IssueQuery", "Open bugs of version 1.0, mine first", 2, :john,
    { "status_id" => ["o", [""]], "tracker_id" => ["=", ["1"]], "fixed_version_id" => ["=", ["1"]], "assigned_to_id" => ["=", ["me"]] },
    columns: %w[tracker status subject assigned_to cf_1], sort: [%w[priority desc], %w[id asc]], group_by: "status"),
  query.(2, "IssueQuery", "My issues in progress (private)", 0, :john, { "status_id" => ["=", ["2"]], "assigned_to_id" => ["=", ["5"]] }),
  query.(3, "IssueQuery", "Alice's private query", 0, :alice, { "status_id" => ["o", [""]], "author_id" => ["=", ["6"]] }),
  query.(4, "IssueQuery", "Visible to developers", 1, :john, { "tracker_id" => ["=", ["2"]] }, roles: [:developer]),
  query.(5, "IssueQuery", "High priority, open", 2, :paula, { "priority_id" => ["=", %w[3 4 5]], "status_id" => ["o", [""]] }),
  query.(6, "IssueQuery", "Subject contains export", 2, :tom, { "subject" => ["~", ["export"]] }, columns: %w[subject updated_on], sort: [%w[updated_on desc]]),
  query.(7, "IssueQuery", "Sprint 3 (Scrum filter, no local equivalent)", 2, :john, { "sprint_id" => ["=", ["3"]] }),
  query.(8, "IssueQuery", "A named subproject (no local equivalent)", 2, :john, { "subproject_id" => ["=", ["2"]] }),
  query.(9, "IssueQuery", "Tagged URGENT (tag filter, no local equivalent)", 2, :john, { "issue_tags" => ["=", ["URGENT"]] }),
  query.(10, "TimeEntryQuery", "Development time this month", 2, :paula,
    { "activity_id" => ["=", ["9"]], "issue.tracker_id" => ["=", ["2"]], "spent_on" => ["m", [""]] }),
  query.(11, "AgileQuery", "Kanban board (needs an agile plugin)", 2, :john, { "tracker_id" => ["=", %w[1 2 4]] },
    columns: %w[id priority assigned_to], options: { "f_status" => %w[1 2 3], "wp" => { "2" => "3" }, "color_base" => "tracker",
      "sprints_enabled" => 0, "sprint_id" => nil, "is_default" => false, "draw_relations" => nil })
]

TAGS = { "[Agile] Tags with" => ["Front end", "café", "URGENT"], "[Text] Textile" => ["Front end"], "[State] Private" => ["security", "URGENT"],
  "[Files] One attachment" => ["files"], "[Watch]" => ["URGENT"] }.freeze
SPRINTS = [
  { "id" => 1, "name" => "Sprint 1", "description" => "Closed, with one issue still open", "start_date" => "2026-09-01", "end_date" => "2026-09-14",
    "status" => "closed", "shared" => false, "product_backlog" => false },
  { "id" => 2, "name" => "Sprint 2", "description" => "", "start_date" => "2026-09-15", "end_date" => "2026-09-28", "status" => "locked",
    "shared" => true, "product_backlog" => false },
  { "id" => 3, "name" => "Sprint 3", "description" => "", "start_date" => "2026-09-29", "end_date" => "2026-10-12", "status" => "open",
    "shared" => false, "product_backlog" => false },
  { "id" => 4, "name" => "Sprint 1", "description" => "Same name as an older sprint", "start_date" => "2026-10-13", "end_date" => "2026-10-26",
    "status" => "open", "shared" => false, "product_backlog" => false },
  { "id" => 5, "name" => "Product backlog", "description" => "", "start_date" => nil, "end_date" => nil, "status" => "open", "shared" => false,
    "product_backlog" => true }
].map { |sprint| sprint.merge("created_on" => time(1, 8)) }.freeze
SPRINT_OF = { "[Text] Textile" => [1, "3"], "[Agile] In a sprint," => [3, "5"], "[Agile] In a sprint of another" => [7, nil],
  "[Agile] Moved between" => [3, "2"], "[Time] Time by several" => [2, "8"], "[State] Dates" => [3, "0.5"] }.freeze

# ---------------------------------------------------------------------------------------
# The answers, keyed as the replay looks them up.

@answers = {}
def key(path, params)
  params.empty? ? path : "#{path}?#{URI.encode_www_form(params.map { |name, value| [name.to_s, value.to_s] }.sort)}"
end
def answer(path, params, body)
  @answers[key(path, params)] = { "body" => body }
end
def refuse(path, params, status)
  @answers[key(path, params)] = { "error" => "Redmine API returned HTTP #{status} for GET #{path}" }
end
def page(collection, rows, params)
  rows.each_slice(100).with_index do |slice, index|
    answer("#{collection}.json", params.merge("limit" => 100, "offset" => index * 100),
      collection => slice, "total_count" => rows.size, "offset" => index * 100, "limit" => 100)
  end
end

project = { "id" => 1, "name" => PROJECT["name"], "identifier" => "mirror-demo",
  "description" => "Demo project of Redmine Mirror: each issue shows one case.", "homepage" => "", "status" => 1, "is_public" => false }
dates = { "created_on" => time(1, 8), "updated_on" => time(1, 8) }
answer("projects/1.json", {}, "project" => project.merge(dates))
SOURCE_MODULES = %w[issue_tracking time_tracking news documents files wiki mirror_source scrum].freeze
answer("projects/1.json", { "include" => "enabled_modules" },
  "project" => project.merge("enabled_modules" => SOURCE_MODULES.each_with_index.map { |name, index| { "id" => index + 1, "name" => name } }).merge(dates))
answer("projects/1.json", { "include" => "trackers" }, "project" => project.merge("trackers" => TRACKERS.map { |id, name| { "id" => id, "name" => name } }).merge(dates))
answer("issue_statuses.json", {}, "issue_statuses" => STATUSES.map { |id, name, closed| { "id" => id, "name" => name, "is_closed" => closed } })
answer("enumerations/issue_priorities.json", {}, "issue_priorities" => PRIORITIES.map { |id, name| { "id" => id, "name" => name, "is_default" => id == 2 } })
answer("enumerations/time_entry_activities.json", {}, "time_entry_activities" => ACTIVITIES.map { |id, name| { "id" => id, "name" => name, "is_default" => id == 9 } })
answer("enumerations/document_categories.json", {}, "document_categories" => DOCUMENT_CATEGORIES.map { |id, name| { "id" => id, "name" => name, "is_default" => false } })
# The reader account is neither administrator nor category manager.
refuse("custom_fields.json", {}, 403)
refuse("projects/1/issue_categories.json", {}, 403)
answer("projects/1/versions.json", {}, "versions" => VERSIONS.map { |version| version.merge(dates) })
VERSIONS.each { |version| answer("versions/#{version['id']}.json", {}, "version" => version.merge(dates)) }
MEMBERS = [[:john, [:manager]], [:alice, [:reporter, :client]], [:reader, [:reader]], [:bob, [:developer]], [:tom, [:developer]], [:paula, [:manager]]].freeze
answer("projects/1/memberships.json", { "limit" => 100, "offset" => 0 },
  "memberships" => MEMBERS.each_with_index.map { |(key, roles), index| { "id" => index + 1, "project" => PROJECT, "user" => user(key), "roles" => roles.map { |role| ref(ROLES, role) } } },
  "total_count" => MEMBERS.size, "offset" => 0, "limit" => 100)
# The inventory of the setup checklist counts each collection with one row.
answer("projects/1/memberships.json", { "limit" => 1 }, "memberships" => [], "total_count" => MEMBERS.size, "offset" => 0, "limit" => 1)
answer("projects/1/versions.json", { "limit" => 1 }, "versions" => [], "total_count" => VERSIONS.size)
refuse("projects/1/issue_categories.json", { "limit" => 1 }, 403)
# Nor does it share its categories: Mirror reads them from the issues.
@answers["projects/1/mirror/source/issue_categories.json"] = { "error" => "Redmine API returned HTTP 403 for GET projects/1/mirror/source/issue_categories.json (Mirror source: not_shared)" }
# Nor does it share its custom field definitions: Mirror observes values on issues.
@answers["projects/1/mirror/source/custom_fields.json"] = { "error" => "Redmine API returned HTTP 403 for GET projects/1/mirror/source/custom_fields.json (Mirror source: not_shared)" }
# Localizable is absent from the demo source.
answer("projects/1/mirror/source/localized_names.json", {}, "localized_names" => {})
# The demo project has no subproject running Mirror source.
answer("projects/1/mirror/source/subprojects.json", {}, "subprojects" => [], "total_count" => 0)
# The source does not share its users' details (Mirror source); any list of IDs gets this answer.
@answers["projects/1/mirror/source/users.json"] = { "error" => "Redmine API returned HTTP 403 for GET projects/1/mirror/source/users.json (Mirror source: not_shared)" }

LIST_KEYS = %w[id project tracker status priority author assigned_to category fixed_version parent subject description start_date due_date
  done_ratio is_private estimated_hours custom_fields created_on updated_on closed_on].freeze
page("issues", ISSUES.map { |record| record.slice(*LIST_KEYS) }, "project_id" => 1, "sort" => "id:asc", "status_id" => "*", "subproject_id" => "!*")
ISSUES.each do |record|
  spent = @time_entries.select { |entry| entry.dig("issue", "id") == record["id"] }.sum { |entry| entry["hours"] }
  detail = record.slice(*LIST_KEYS.first(LIST_KEYS.index("estimated_hours") + 1))
  detail.merge!("total_estimated_hours" => record["estimated_hours"], "spent_hours" => spent, "total_spent_hours" => spent)
  detail.merge!(record.slice("custom_fields", "created_on", "updated_on", "closed_on"))
  nested = children.call(record["id"])
  detail["children"] = nested unless nested.empty?
  detail.merge!(record.slice("attachments", "relations", "journals", "watchers"))
  answer("issues/#{record['id']}.json", { "include" => "journals,attachments,relations,watchers,children" }, "issue" => detail)
end
# The partner portal is not visible to the reader account.
refuse("issues/#{partner_issue['id']}.json", { "include" => "journals,attachments,relations,watchers,children" }, 403)
page("time_entries", @time_entries, "project_id" => 1, "sort" => "id:asc")

wiki_path = ->(title) { "projects/1/wiki/#{ERB::Util.url_encode(title)}" }
answer("projects/1/wiki/index.json", {}, "wiki_pages" => @wiki.map do |wiki_page|
  current = wiki_page["versions"].last
  { "title" => current["title"], "parent" => current["parent"], "version" => current["version"], "created_on" => current["created_on"],
    "updated_on" => current["updated_on"] }.compact
end)
@wiki.each do |wiki_page|
  current = wiki_page["versions"].last
  answer("#{wiki_path.(current['title'])}.json", { "include" => "attachments" }, "wiki_page" => current.merge("attachments" => wiki_page["attachments"]))
  wiki_page["versions"].each { |version| answer("#{wiki_path.(current['title'])}/#{version['version']}.json", {}, "wiki_page" => version) }
end
answer("projects/1/wiki.json", {}, "wiki_page" => @wiki.first["versions"].last)

answer("projects/1/files.json", {}, "files" => @files)
answer("projects/1/mirror/source/documents.json", {}, "documents" => @documents, "total_count" => @documents.size)
answer("projects/1/mirror/source/news.json", {}, "news" => @news, "total_count" => @news.size)
answer("projects/1/mirror/source/queries.json", {}, "queries" => @queries, "total_count" => @queries.size)
tags = ISSUES.map { |record| { "id" => record["id"], "tags" => TAGS.find { |prefix, _| record["subject"].start_with?(prefix) }&.last || [] } }
answer("projects/1/mirror/source/issue_tags.json", {}, "issue_tags" => tags, "total_count" => tags.size)
sprint_issues = ISSUES.each_with_index.map do |record, index|
  sprint, points = SPRINT_OF.find { |prefix, _| record["subject"].start_with?(prefix) }&.last || [5, nil]
  { "id" => record["id"], "sprint_id" => sprint, "position" => index + 1, "story_points" => points }
end
answer("projects/1/mirror/source/scrum.json", {}, "scrum" => { "sprints" => SPRINTS, "issues" => sprint_issues })

# ---------------------------------------------------------------------------------------
# Write: answers, downloads, files and meta, sorted for stable diffs.

FileUtils.rm_rf(File.join(OUT, "files"))
FileUtils.mkdir_p(File.join(OUT, "files"))
@downloads.each_value do |download|
  next unless download["file"]
  File.binwrite(File.join(OUT, "files", download["file"]), ASSETS.fetch(download["file"]).last)
end
File.write(File.join(OUT, "answers.json"), JSON.pretty_generate(@answers.sort.to_h) + "\n")
File.write(File.join(OUT, "downloads.json"), JSON.pretty_generate(@downloads.sort.to_h) + "\n")
File.write(File.join(OUT, "meta.json"), JSON.pretty_generate("project_id" => 1, "generated_by" => "generate.rb") + "\n")
puts "#{ISSUES.size} issues, #{ISSUES.sum { |row| row['journals'].size }} journals, #{@time_entries.size} time entries, " \
  "#{@wiki.size} wiki pages, #{@downloads.size} downloads, #{@answers.size} answers"
