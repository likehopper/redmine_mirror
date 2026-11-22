# frozen_string_literal: true
# File: redmine_mirror/test/environment/source_security_source_check.rb

abort "Disposable source only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
project = Project.find_by!(identifier: "mirror-documents-demo")
reader = User.find_by!(login: "mirror-reader")
accesses = project.mirror_source_accesses.order(:id).to_a
raise "Authorized account not logged" unless accesses.any? { |row| row.action == "list" && row.user_id == reader.id }
raise "Application-key refusals not logged" unless accesses.count { |row| row.action == "refused" && row.reason == "client_key" } == 2
raise "Private object metadata logged" unless accesses.all? { |row| row.details == { "kind" => "documents" } }
serialized = accesses.map(&:details).to_json
raise "Document titles leaked to the access log" if serialized.include?("Architecture") || serialized.include?("User guide")

puts "Source security log check passed: account and refusals recorded without titles, filenames, emails or keys"
