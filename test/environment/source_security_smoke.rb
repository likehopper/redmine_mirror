# frozen_string_literal: true
# File: redmine_mirror/test/environment/source_security_smoke.rb

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
config = JSON.parse(File.read(ENV.fetch("MIRROR_CONFIG")))
url = config.fetch("source_url")
api_key = ENV.fetch("MIRROR_SOURCE_API_KEY")
application_key = ENV.fetch("MIRROR_SOURCE_APPLICATION_KEY")
path = "projects/mirror-documents-demo/mirror/source/documents.json"

client = RedmineMirror::Client.new(url: url, api_key: api_key, application_key: application_key,
  allow_http: true, purpose: "preview")
documents = client.get(path).fetch("documents")
raise "Shared documents missing" unless documents.map { |row| row.fetch("title") }.sort == ["Architecture", "User guide"]

[[nil, "missing"], ["wrong-application-key", "wrong"]].each do |key, label|
  refused = RedmineMirror::Client.new(url: url, api_key: api_key, application_key: key, allow_http: true, purpose: "preview")
  begin
    refused.get(path)
    raise "#{label} application key was accepted"
  rescue RedmineMirror::Error => error
    raise unless error.message.include?("application key")
  end
end

puts "Source security smoke passed: authorized Mirror served documents; missing and wrong application keys refused"
