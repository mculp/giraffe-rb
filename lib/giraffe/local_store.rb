# frozen_string_literal: true

require "digest"
require_relative "store"

module Giraffe
  # Local journals are authoritative on the execution host. The journals themselves are the outbox:
  # rebuilding a sync batch never depends on a separate queue entry surviving a crash.
  class LocalStore
    attr_reader :path, :run_id, :context

    def initialize(path:, run_id:, context: nil, ticket:, mirror: true, cli: PrGraph::TemperCli.new)
      @path, @run_id, @context, @ticket, @mirror, @cli = path, run_id, context, ticket, mirror, cli
    end

    def event_log = @event_log ||= LiveEventLog.new(self)
    def artifact_log = @artifact_log ||= LiveArtifactLog.new(self, execution_log: event_log)
    def failure_log = @failure_log ||= LiveFailureLog.new(self, execution_log: event_log)
    def coordinator(execution_path:, session:)
      LiveCoordinator.new(self, execution_path: execution_path, run_id: run_id, session: session,
                              event_log: event_log, artifact_log: artifact_log, failure_log: failure_log)
    end

    def commit(kind:, content:, **)
      raise Error, "unsupported local record kind #{kind}" unless kind == PrGraph::Shapes::HARNESS
      json = JSON.generate(content)
      raise Error, "state was not stored: #{reason}" if (reason = PrGraph::ContentScan.violation(content, json))
      target = path.sub(/\.jsonl\z/, ".state.jsonl")
      File.open(target, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(json + "\n")
        file.flush
        file.fsync
      end
      live { remote.commit(kind: "giraffe-harness-live", content: content, precedence: content.fetch("revision"), correlation: run_id) }
      content["revision"].to_s
    end

    def read_records(kind)
      raise Error, "unsupported local record kind #{kind}" unless kind == PrGraph::Shapes::HARNESS
      File.open(path.sub(/\.jsonl\z/, ".state.jsonl")) do |file|
        file.flock(File::LOCK_SH)
        file.each_line.map { |line| JSON.parse(line) }
      end
    rescue JSON::ParserError
      raise Error, "local state journal is damaged; recover from the last Temper checkpoint"
    end

    def sync(state)
      return {"mode" => "local", "synced" => false} unless @mirror
      remote = self.remote
      logs = {
        PrGraph::Shapes::EVENT_LOG => event_log.validate_file!(path),
        PrGraph::Shapes::ARTIFACT_LOG => artifact_log.read(path.sub(/\.jsonl\z/, ".artifacts.jsonl"), allow_empty: true),
        PrGraph::Shapes::FAILURE_LOG => failure_log.read(path.sub(/\.jsonl\z/, ".failures.jsonl"), allow_empty: true)
      }
      coordinator(execution_path: path, session: state.fetch("session")).snapshot
      # Evidence before the log rows referring to it. The remote copy may be ahead of the last fully
      # synced checkpoint if an earlier sync was interrupted; matching writes are safe to repeat.
      logs.fetch(PrGraph::Shapes::ARTIFACT_LOG).select { |row| row["e"] == "artifact" }.group_by { |row| row["family"] }.each do |family, rows|
        kind = PrGraph::Shapes.family_kind(family)
        held = remote.read_records(kind)
        rows.each do |row|
          bytes = File.read(File.join(File.dirname(path), row.fetch("content_ref")))
          content = {"record" => row, "content" => bytes}
          next if held.include?(content)
          remote.commit_evidence(row, bytes)
        end
      end
      manifests = Dir.glob(path.sub(/\.jsonl\z/, ".coordinator/*.json")).sort.to_h { |file| [File.basename(file), File.read(file)] }
      held = remote.read_records(PrGraph::Shapes::MANIFEST)
      manifests.each do |name, text|
        next if held.include?({"name" => name, "text" => text})
        raise Error, "Temper has a different coordinator manifest #{name}" if held.any? { |row| row["name"] == name }
        remote.commit_manifest(name, text)
      end
      logs.each do |kind, rows|
        held_rows = remote.read_records(kind).flat_map { |row| row.fetch("events") }.uniq
        raise Error, "Temper history diverges from this local run" unless held_rows.all? { |row| rows.include?(row) }
        rows.each do |row|
          next if held_rows.include?(row)
          digest = Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
          uuid = [digest[0, 8], digest[8, 4], digest[12, 4], digest[16, 4], digest[20, 12]].join("-")
          remote.commit(kind: kind, content: {"transition_id" => uuid, "events" => [row]}, precedence: row.fetch("seq"), correlation: run_id)
        end
      end
      checkpoint = {"logs" => logs.transform_values(&:length), "manifests" => manifests.transform_values { |text| Digest::SHA256.hexdigest(text) }}
      remote_state = state.merge("runtime" => state.fetch("runtime").merge("sync_checkpoint" => checkpoint))
      unless remote.read_records(PrGraph::Shapes::HARNESS).include?(remote_state)
        remote.commit(kind: PrGraph::Shapes::HARNESS, content: remote_state, precedence: state.fetch("revision"), correlation: run_id)
      end
      status = {"mode" => "mirrored", "synced" => true, "revision" => state["revision"], "event_seq" => logs[PrGraph::Shapes::EVENT_LOG].length}
      write_sync_status(status)
      status
    rescue StandardError => error
      status = {"mode" => "mirrored", "synced" => false, "error" => error.message}
      write_sync_status(status)
      status
    end

    def live_transition(kind, rows, log_path)
      live do
        if kind == PrGraph::Shapes::ARTIFACT_LOG
          rows.select { |row| row["e"] == "artifact" }.each do |row|
            remote.commit_evidence(row, File.binread(File.join(File.dirname(log_path), row.fetch("content_ref"))))
          end
        end
        rows.each do |row|
          digest = Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
          uuid = [digest[0, 8], digest[8, 4], digest[12, 4], digest[16, 4], digest[20, 12]].join("-")
          remote.commit(kind: kind, content: {"transition_id" => uuid, "events" => [row]}, precedence: row.fetch("seq"), correlation: run_id)
        end
      end
    end

    def live_manifest(file)
      live { remote.commit_manifest(File.basename(file), File.read(file)) }
    end

    private

    def remote
      @remote ||= PrGraph::Store.new(context: context, run_id: run_id, ticket: @ticket, cli: @cli, backoff: [], versioned: true).open!
    end

    def live
      return unless @mirror
      write_sync_status({"mode" => "mirrored", "synced" => false, "pending_checkpoint" => true})
      yield
    rescue StandardError => error
      write_sync_status({"mode" => "mirrored", "synced" => false, "error" => error.message})
    end

    def write_sync_status(status)
      target = path.sub(/\.jsonl\z/, ".sync.json")
      temporary = "#{target}.tmp"
      File.open(temporary, "w", 0o600) { |file| file.write(JSON.generate(status)); file.flush; file.fsync }
      File.rename(temporary, target)
    end
  end
  class LiveEventLog < PrGraph::EventLog
    def initialize(store) = (@store = store; super())
    private
    def append!(path, additions)
      super
      @store.live_transition(PrGraph::Shapes::EVENT_LOG, additions, path)
    end
  end

  class LiveArtifactLog < PrGraph::ArtifactLog
    def initialize(store, **options) = (@store = store; super(**options))
    private
    def append!(path, additions)
      super
      @store.live_transition(PrGraph::Shapes::ARTIFACT_LOG, additions, path)
    end
  end

  class LiveFailureLog < PrGraph::FailureLog
    def initialize(store, **options) = (@store = store; super(**options))
    private
    def append_events!(path, additions)
      super
      @store.live_transition(PrGraph::Shapes::FAILURE_LOG, additions, path)
    end
  end

  class LiveCoordinator < PrGraph::Coordinator
    def initialize(store, **options) = (@store = store; super(**options))
    private
    def write_manifest!(path, manifest)
      super
      @store.live_manifest(path)
    end
  end

end
