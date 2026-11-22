# frozen_string_literal: true
# File: redmine_mirror/db/migrate/026_create_mirror_sync_run_events.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# One row per logged object instead of one JSON document per execution: appending no
# longer rewrites the whole journal, pages are filtered and paginated by the database,
# and large journals no longer exceed a MySQL TEXT column. Runs also keep their live
# progress (phase and module counters) for the execution page.

class CreateMirrorSyncRunEvents < ActiveRecord::Migration[RedmineMirror.migration_version]
  COLUMNS = %w[module source_id destination_id action reason].freeze
  BATCH_SIZE = 500

  def up
    create_table :mirror_sync_run_events do |t|
      t.integer :run_id, null: false
      t.string :module_key, null: false, limit: 64
      t.string :source_id, limit: 255
      t.string :destination_id, limit: 255
      t.string :action, null: false, limit: 32
      t.text :reason
      t.text :data
    end
    add_index :mirror_sync_run_events, [:run_id, :module_key, :action], name: "mirror_sync_run_events_summary"
    add_index :mirror_sync_run_events, [:run_id, :action], name: "mirror_sync_run_events_action"
    add_column :mirror_sync_runs, :progress, :text
    copy_journals
  end

  def down
    rebuild_journals
    remove_column :mirror_sync_runs, :progress
    drop_table :mirror_sync_run_events
  end

  private

  # Moves each JSON journal into rows, then empties the column it came from.
  def copy_journals
    select_values("SELECT id FROM mirror_sync_runs WHERE events IS NOT NULL").each do |run_id|
      json = select_value("SELECT events FROM mirror_sync_runs WHERE id = #{Integer(run_id)}")
      events = begin
        JSON.parse(json.presence || "[]")
      rescue JSON::ParserError
        # A journal cut by a size limit cannot be read back; its run keeps its totals.
        []
      end
      events.each_slice(BATCH_SIZE) do |slice|
        rows = slice.select { |event| event.is_a?(Hash) }.map { |event| row(Integer(run_id), event) }
        insert_rows(rows) if rows.any?
      end
      execute("UPDATE mirror_sync_runs SET events = NULL WHERE id = #{Integer(run_id)}")
    end
  end

  def rebuild_journals
    select_values("SELECT DISTINCT run_id FROM mirror_sync_run_events").each do |run_id|
      rows = select_all("SELECT module_key, source_id, destination_id, action, reason, data FROM mirror_sync_run_events " \
        "WHERE run_id = #{Integer(run_id)} ORDER BY id").to_a
      events = rows.map do |row|
        event = { "module" => row["module_key"], "source_id" => identifier(row["source_id"]) }
        event["destination_id"] = identifier(row["destination_id"]) unless row["destination_id"].nil?
        event["action"] = row["action"]
        event["reason"] = row["reason"] unless row["reason"].nil?
        event.merge(row["data"].present? ? JSON.parse(row["data"]) : {})
      end
      execute("UPDATE mirror_sync_runs SET events = #{quote(JSON.generate(events))} WHERE id = #{Integer(run_id)}")
    end
  end

  def row(run_id, event)
    data = event.except(*COLUMNS)
    [run_id, event["module"].to_s, event["source_id"]&.to_s, event["destination_id"]&.to_s,
      event["action"].to_s, event["reason"]&.to_s, data.empty? ? nil : JSON.generate(data)]
  end

  # Plain multi-row INSERT: Rails 5.2 (Redmine 4 sources) has no insert_all.
  def insert_rows(rows)
    values = rows.map { |values_row| "(#{values_row.map { |value| quote(value) }.join(', ')})" }.join(", ")
    execute("INSERT INTO mirror_sync_run_events (run_id, module_key, source_id, destination_id, action, reason, data) VALUES #{values}")
  end

  def identifier(value)
    value&.match?(/\A\d+\z/) ? Integer(value) : value
  end

  def quote(value)
    connection.quote(value)
  end
end
