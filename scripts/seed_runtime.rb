#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"
require_relative "seed_contract"

module PrGraph
  class SeedRuntime
    RESULT_MARKER = "PR_GRAPH_SEED_MANIFEST=".freeze
    REMOTE_KEYS = %w[candidate_sha cleanup error observed_at run_id scenarios schema_version status target].freeze

    attr_reader :captured_stderr, :captured_stdout, :contract

    def initialize(contract: SeedContract.new, clock: -> { Time.now.utc }, command_runner: nil)
      @contract = contract
      @clock = clock
      @command_runner = command_runner || method(:capture)
      @captured_stdout = ""
      @captured_stderr = ""
    end

    def prepare(plan:, script_path:, manifest_path:)
      contract.validate_plan!(plan)
      lock = manifest_lock(manifest_path)
      script = render(plan)
      script_sha = Digest::SHA256.hexdigest(script)
      write_file(script_path, script)

      existing = read_manifest(manifest_path)
      if existing
        contract.validate_manifest!(existing, plan: plan)
        unless existing["script_sha256"] == script_sha
          error!("existing seed manifest belongs to a different approved script")
        end
        return existing
      end

      manifest = initial_manifest(plan, script_sha)
      contract.validate_manifest!(manifest, plan: plan)
      write_manifest(manifest_path, manifest)
      manifest
    ensure
      release_lock(lock)
    end

    def execute(plan:, script_path:, manifest_path:, approved_sha:, command:)
      contract.validate_plan!(plan)
      lock = manifest_lock(manifest_path)
      @captured_stdout = ""
      @captured_stderr = ""
      expected_script = render(plan)
      actual_script = File.binread(script_path)
      error!("prepared seed script does not match the plan") unless actual_script == expected_script

      script_sha = Digest::SHA256.hexdigest(actual_script)
      existing = read_manifest(manifest_path)
      if existing
        contract.validate_manifest!(existing, plan: plan)
        error!("seed manifest script hash changed") unless existing["script_sha256"] == script_sha
      end

      if contract.active_scenarios(plan).empty?
        manifest = initial_manifest(plan, script_sha, status: "no_op")
        contract.validate_manifest!(manifest, plan: plan)
        write_manifest(manifest_path, manifest)
        return manifest
      end

      error!("seed script approval SHA is required") if approved_sha.to_s.empty?
      error!("seed script approval SHA does not match the prepared script") unless approved_sha == script_sha
      error!("seed runner command is required") unless command.is_a?(Array) && command.any?
      command.each { |part| error!("seed runner command contains an invalid argument") unless valid_argument?(part) }

      running = initial_manifest(plan, script_sha, status: "running", command: command, invocation_count: 1)
      contract.validate_manifest!(running, plan: plan)
      write_manifest(manifest_path, running)

      begin
        stdout, stderr, exit_status = invoke_once(command, actual_script)
        @captured_stdout = stdout
        @captured_stderr = stderr
      rescue SystemCallError => e
        @captured_stderr = e.message
        final = uncertain_manifest(plan, script_sha, command, "", e.message, nil, error: e)
        contract.validate_manifest!(final, plan: plan)
        write_manifest(manifest_path, final)
        return final
      end

      begin
        remote = parse_remote_result(stdout)
        final = if remote
                  manifest_from_remote(remote, plan, script_sha, command, stdout, stderr, exit_status)
                else
                  uncertain_manifest(plan, script_sha, command, stdout, stderr, exit_status)
                end
        final = preserve_original_cleanup(final, existing)
        contract.validate_manifest!(final, plan: plan)
      rescue ContractError => e
        final = uncertain_manifest(plan, script_sha, command, stdout, stderr, exit_status, error: e)
        contract.validate_manifest!(final, plan: plan)
      end
      write_manifest(manifest_path, final)
      final
    ensure
      release_lock(lock)
    end

    def render(plan)
      contract.validate_plan!(plan)
      encoded = Base64.strict_encode64(JSON.generate(plan))
      remote_script(encoded, JSON.pretty_generate(plan))
    end

    private

    def capture(command, script)
      stdout, stderr, status = Open3.capture3(*command, script)
      [stdout, stderr, status.exitstatus]
    end

    def manifest_lock(path)
      directory = File.dirname(File.expand_path(path))
      FileUtils.mkdir_p(directory)
      lock = File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600)
      acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
      unless acquired
        lock.close
        error!("another seed process owns the mutation manifest")
      end
      lock
    rescue SystemCallError => e
      lock.close if lock && !lock.closed?
      error!("cannot lock seed manifest: #{e.message}")
    end

    def release_lock(lock)
      return unless lock

      lock.flock(File::LOCK_UN)
      lock.close
    end

    def invoke_once(command, script)
      result = @command_runner.call(command, script)
      error!("seed command runner returned an invalid result") unless result.is_a?(Array) && result.length == 3
      stdout, stderr, exit_status = result
      error!("seed command runner stdout must be a string") unless stdout.is_a?(String)
      error!("seed command runner stderr must be a string") unless stderr.is_a?(String)
      unless exit_status.nil? || exit_status.is_a?(Integer)
        error!("seed command runner exit status must be an integer or null")
      end
      result
    end

    def parse_remote_result(stdout)
      line = stdout.lines.reverse.find { |candidate| candidate.start_with?(RESULT_MARKER) }
      return nil unless line

      parsed = JSON.parse(line.delete_prefix(RESULT_MARKER))
      error!("remote seed result must be a JSON object") unless parsed.is_a?(Hash)
      missing = REMOTE_KEYS - parsed.keys
      unknown = parsed.keys - REMOTE_KEYS
      error!("remote seed result missing field(s): #{missing.join(', ')}") if missing.any?
      error!("remote seed result has unknown field(s): #{unknown.join(', ')}") if unknown.any?
      parsed
    rescue JSON::ParserError => e
      error!("remote seed result is invalid JSON: #{e.message}")
    end

    def manifest_from_remote(remote, plan, script_sha, command, stdout, stderr, exit_status)
      unless remote.values_at("run_id", "candidate_sha", "target") == plan.values_at("run_id", "candidate_sha", "target")
        error!("remote seed result identity does not match the approved plan")
      end

      manifest = remote.merge(
        "script_sha256" => script_sha,
        "runner" => runner(command, exit_status, 1, stdout, stderr)
      )
      if exit_status != 0 && remote["status"] == "succeeded"
        manifest["status"] = "uncertain"
        manifest["error"] = error_hash("RunnerExit", "runner exited nonzero after reporting success")
        manifest["cleanup"]["status"] = "unknown"
        manifest["cleanup"]["required"] = true
        manifest["cleanup"]["residuals"] << "runner exited nonzero after remote mutations succeeded"
        manifest["cleanup"]["actions"].each do |action|
          action["status"] = "unknown" if action["status"] == "pending"
        end
      end
      manifest
    end

    def uncertain_manifest(plan, script_sha, command, stdout, stderr, exit_status, error: nil)
      message = if error
                  error.message
                elsif exit_status.nil?
                  "runner returned no exit status or structured manifest"
                else
                  "runner exited #{exit_status} without a structured manifest"
                end
      initial_manifest(
        plan,
        script_sha,
        status: "uncertain",
        command: command,
        invocation_count: 1,
        exit_status: exit_status,
        stdout: stdout,
        stderr: stderr,
        error: error_hash(error ? error.class.name : "RunnerFailure", message),
        cleanup: {
          "required" => true,
          "status" => "unknown",
          "actions" => [],
          "residuals" => ["remote mutation state is unknown; inspect the target before retrying"]
        }
      )
    end

    def initial_manifest(plan, script_sha, status: nil, command: [], invocation_count: 0,
                         exit_status: nil, stdout: nil, stderr: nil, error: nil, cleanup: nil)
      status ||= contract.active_scenarios(plan).empty? ? "no_op" : "prepared"
      results = plan.fetch("scenarios").map do |scenario|
        {
          "id" => scenario.fetch("id"),
          "description" => scenario.fetch("description"),
          "idempotency_key" => contract.stable_key(plan.fetch("run_id"), scenario.fetch("id"), "scenario"),
          "status" => scenario["ruby"] ? "pending" : "skipped",
          "mutations" => []
        }
      end
      {
        "schema_version" => 1,
        "run_id" => plan.fetch("run_id"),
        "candidate_sha" => plan.fetch("candidate_sha"),
        "target" => plan.fetch("target"),
        "script_sha256" => script_sha,
        "status" => status,
        "observed_at" => observed_at,
        "runner" => runner(command, exit_status, invocation_count, stdout, stderr),
        "scenarios" => results,
        "cleanup" => cleanup || {"required" => false, "status" => "not_required", "actions" => [], "residuals" => []},
        "error" => error
      }
    end

    def runner(command, exit_status, invocation_count, stdout, stderr)
      {
        "command" => sanitized_command(command),
        "exit_status" => exit_status,
        "invocation_count" => invocation_count,
        "stdout_sha256" => stdout && Digest::SHA256.hexdigest(stdout),
        "stderr_sha256" => stderr && Digest::SHA256.hexdigest(stderr)
      }
    end

    def sanitized_command(command)
      redact_next = false
      Array(command).map do |part|
        if redact_next
          redact_next = false
          "[REDACTED]"
        elsif part.match?(/\A--?(?:access[-_]?token|authorization|cookie|password|secret|token)\z/i)
          redact_next = true
          part
        elsif part.match?(/\A(?:access[-_]?token|authorization|cookie|password|secret|token)=/i)
          part.sub(/=.*/, "=[REDACTED]")
        else
          part
        end
      end
    end

    def preserve_original_cleanup(current, previous)
      return current unless previous && previous["status"] == "succeeded"
      return current unless previous.values_at("run_id", "candidate_sha", "script_sha256") ==
                            current.values_at("run_id", "candidate_sha", "script_sha256")

      prior = previous.fetch("scenarios").flat_map do |scenario|
        scenario.fetch("mutations").map do |mutation|
          [[scenario.fetch("id"), mutation.fetch("kind"), mutation.fetch("identity")], mutation]
        end
      end.to_h
      prior_actions = Array(previous.dig("cleanup", "actions")).to_h do |action|
        [[action.fetch("kind"), action.fetch("identity")], action]
      end
      current.fetch("scenarios").each do |scenario|
        scenario.fetch("mutations").each do |mutation|
          original = prior[[scenario.fetch("id"), mutation.fetch("kind"), mutation.fetch("identity")]]
          next unless original && original["changed"]

          mutation["action"] = original["action"]
          mutation["created"] = original["created"]
          mutation["changed"] = true
          mutation["previous"] = original["previous"]
          mutation["cleanup"] = original["cleanup"]
          action = current.dig("cleanup", "actions").find do |candidate|
            candidate["kind"] == mutation["kind"] && candidate["identity"] == mutation["identity"]
          end
          original_action = prior_actions[[mutation["kind"], mutation["identity"]]]
          next unless action && original_action

          action["instruction"] = original_action["instruction"]
          action["status"] = "pending"
        end
      end
      if current.dig("cleanup", "actions").any? { |action| action["status"] == "pending" }
        current["cleanup"]["required"] = true
        current["cleanup"]["status"] = "available"
      end
      current
    end

    def read_manifest(path)
      return nil unless File.exist?(path)

      JSON.parse(File.binread(path))
    rescue JSON::ParserError => e
      error!("existing seed manifest is invalid JSON: #{e.message}")
    end

    def write_manifest(path, manifest)
      write_file(path, JSON.pretty_generate(manifest) + "\n")
    end

    def write_file(path, content)
      directory = File.dirname(File.expand_path(path))
      FileUtils.mkdir_p(directory)
      Tempfile.create([".pr-graph-seed", ".tmp"], directory) do |file|
        file.binmode
        file.write(content)
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end

    def observed_at
      @clock.call.utc.iso8601(6)
    end

    def valid_argument?(value)
      value.is_a?(String) && !value.empty? && !value.include?("\0")
    end

    def error_hash(klass, message)
      {"class" => klass.to_s, "message" => message.to_s.lines.first.to_s.chomp}
    end

    def error!(message)
      raise SeedContract::SeedError, message
    end

    def remote_script(encoded_plan, readable_plan)
      plan_comment = readable_plan.lines.map { |line| "        # #{line}" }.join
      <<~RUBY
        # frozen_string_literal: true
        # Approved seed plan (the executable copy is encoded below):
#{plan_comment}
        require "base64"
        require "digest"
        require "json"
        require "time"

        plan = JSON.parse(Base64.strict_decode64("#{encoded_plan}"))

        class PrGraphSeedFailure < StandardError; end

        class PrGraphSeed
          attr_reader :results

          def initialize(plan)
            @plan = plan
            @run_id = plan.fetch("run_id")
            @results = plan.fetch("scenarios").map do |scenario|
              {
                "id" => scenario.fetch("id"),
                "description" => scenario.fetch("description"),
                "idempotency_key" => stable_key_for(scenario.fetch("id"), "scenario"),
                "status" => scenario["ruby"] ? "pending" : "skipped",
                "mutations" => []
              }
            end
            @cleanup_actions = []
            @restorers = []
            @current = nil
          end

          def stable_key(label)
            text = label.to_s
            unless text.match?(/\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z/)
              raise PrGraphSeedFailure, "invalid stable-key label"
            end
            stable_key_for(@current.fetch("id"), text)
          end

          def ensure_record(label:, find:, create:, cleanup: nil)
            key = stable_key(label)
            record = find.call(key)
            created = record.nil?
            record = create.call(key) if created
            unless record && (!record.respond_to?(:persisted?) || record.persisted?)
              details = record.respond_to?(:errors) ? record.errors.full_messages.join(", ") : "no persisted record returned"
              raise PrGraphSeedFailure, "record creation failed: " + details
            end
            identity = record_identity(record)
            instruction = cleanup || "delete " + identity + " when its seed key is " + key
            mutation(
              kind: "record", identity: identity, action: created ? "created" : "reused",
              created: created, changed: created, previous: nil,
              current: {"seed_key" => key},
              cleanup: instruction, transactional: true
            )
            record
          end

          def update(label:, record:, attributes:)
            raise PrGraphSeedFailure, "update attributes must be a non-empty hash" unless attributes.is_a?(Hash) && !attributes.empty?
            stable_key(label)
            previous = attributes.keys.to_h { |key| [key.to_s, record.public_send(key)] }
            changed = attributes.any? { |key, value| record.public_send(key) != value }
            if changed
              record.assign_attributes(attributes)
              saved = record.save
              unless saved
                details = record.respond_to?(:errors) ? record.errors.full_messages.join(", ") : "save returned false"
                raise PrGraphSeedFailure, "record update failed: " + details
              end
            end
            identity = record_identity(record)
            mutation(
              kind: "record", identity: identity, action: changed ? "updated" : "unchanged",
              created: false, changed: changed, previous: previous,
              current: attributes.keys.to_h { |key| [key.to_s, record.public_send(key)] },
              cleanup: "restore " + identity + " attributes to " + JSON.generate(json_value(previous)),
              transactional: true
            )
            record
          end

          def enable_flag(label:, name:, actor: nil)
            stable_key(label)
            flag = name.to_sym
            previous = actor ? Flipper.enabled?(flag, actor) : Flipper.enabled?(flag)
            identity = "flipper:" + name.to_s + ":" + actor_identity(actor)
            instruction = previous ? "leave " + identity + " enabled" : "disable " + identity
            action = cleanup_action("flag", identity, instruction, previous ? "not_needed" : "pending")
            unless previous
              @restorers << [action, lambda do
                actor ? Flipper.disable(flag, actor) : Flipper.disable(flag)
                restored = actor ? Flipper.enabled?(flag, actor) == previous : Flipper.enabled?(flag) == previous
                raise PrGraphSeedFailure, "feature flag restore did not recover its prior state" unless restored
                true
              end]
              actor ? Flipper.enable(flag, actor) : Flipper.enable(flag)
            end
            current = actor ? Flipper.enabled?(flag, actor) : Flipper.enabled?(flag)
            raise PrGraphSeedFailure, "feature flag did not become enabled" unless current
            mutation(
              kind: "flag", identity: identity, action: previous ? "already_enabled" : "enabled",
              created: false, changed: !previous, previous: previous, current: current,
              cleanup: instruction, transactional: false, registered_action: action
            )
            current
          end

          def nontransactional(label:, kind:, identity:, previous:, cleanup:, apply:, restore:)
            stable_key(label)
            unless apply.respond_to?(:call) && restore.respond_to?(:call)
              raise PrGraphSeedFailure, "nontransactional apply and restore must be callable"
            end
            action = cleanup_action(kind.to_s, identity.to_s, cleanup.to_s, "pending")
            @restorers << [action, restore]
            entry = mutation(
              kind: kind.to_s, identity: identity.to_s, action: "external",
              created: false, changed: true, previous: previous, current: nil,
              cleanup: cleanup.to_s, transactional: false, registered_action: action
            )
            applied = apply.call
            raise PrGraphSeedFailure, "nontransactional apply returned false" if applied == false
            entry["current"] = json_value(applied)
            entry["current"]
          end

          def run
            error = nil
            begin
              ActiveRecord::Base.transaction do
                @plan.fetch("scenarios").each_with_index do |scenario, index|
                  next unless scenario["ruby"]
                  @current = @results.fetch(index)
                  seed = self
                  eval(scenario.fetch("ruby"), binding, "seed-scenario:" + scenario.fetch("id"), 1)
                  @current["status"] = "succeeded"
                end
              end
            rescue StandardError => exception
              error = {"class" => exception.class.name, "message" => exception.message.to_s.lines.first.to_s.chomp}
              @current["status"] = "failed" if @current
              @results.each do |result|
                result["status"] = "rolled_back" if result["status"] == "succeeded"
                result["status"] = "skipped" if result["status"] == "pending"
              end
              rollback_transactional_actions
              restore_nontransactional
            ensure
              @current = nil
            end

            status = error ? "failed" : "succeeded"
            cleanup = cleanup_report(status)
            {
              "schema_version" => 1,
              "run_id" => @plan.fetch("run_id"),
              "candidate_sha" => @plan.fetch("candidate_sha"),
              "target" => @plan.fetch("target"),
              "status" => status,
              "observed_at" => Time.now.utc.iso8601(6),
              "scenarios" => @results,
              "cleanup" => cleanup,
              "error" => error
            }
          end

          private

          def stable_key_for(scenario_id, label)
            "prg-" + Digest::SHA256.hexdigest([@run_id.downcase, scenario_id, label].join("\\0"))[0, 28]
          end

          def mutation(kind:, identity:, action:, created:, changed:, previous:, current:, cleanup:, transactional:, registered_action: nil)
            entry = {
              "kind" => kind.to_s,
              "identity" => identity.to_s,
              "action" => action,
              "created" => created,
              "changed" => changed,
              "previous" => json_value(previous),
              "current" => json_value(current),
              "cleanup" => cleanup.to_s
            }
            @current.fetch("mutations") << entry
            if registered_action.nil?
              registered_action = cleanup_action(kind.to_s, identity.to_s, cleanup.to_s, changed ? "pending" : "not_needed")
            end
            registered_action["transactional"] = transactional
            entry
          end

          def cleanup_action(kind, identity, instruction, status)
            action = {"kind" => kind, "identity" => identity, "instruction" => instruction, "status" => status}
            @cleanup_actions << action
            action
          end

          def rollback_transactional_actions
            @cleanup_actions.each do |action|
              action["status"] = "rolled_back" if action.delete("transactional") && action["status"] == "pending"
            end
          end

          def restore_nontransactional
            @restorers.reverse_each do |action, restore|
              begin
                restored = restore.call
                raise PrGraphSeedFailure, "restore returned false" if restored == false
                action["status"] = "restored"
              rescue StandardError => exception
                action["status"] = "failed"
                action["restore_error"] = exception.class.name + ": " + exception.message.to_s.lines.first.to_s.chomp
              end
            end
          end

          def cleanup_report(status)
            @cleanup_actions.each { |action| action.delete("transactional") }
            residuals = @cleanup_actions.each_with_object([]) do |action, values|
              next unless action["status"] == "failed"
              values << action.fetch("identity") + " restore failed: " + action.delete("restore_error").to_s
            end
            required = status == "succeeded" && @cleanup_actions.any? { |action| action["status"] == "pending" }
            cleanup_status = if residuals.any?
                               "incomplete"
                             elsif status == "failed" && @cleanup_actions.any?
                               "restored"
                             elsif required
                               "available"
                             else
                               "not_required"
                             end
            {"required" => required, "status" => cleanup_status, "actions" => @cleanup_actions, "residuals" => residuals}
          end

          def record_identity(record)
            name = record.class.respond_to?(:name) ? record.class.name : record.class.to_s
            identifier = record.respond_to?(:id) ? record.id : record.object_id
            name.to_s + ":" + identifier.to_s
          end

          def actor_identity(actor)
            return "global" unless actor
            return actor.flipper_id.to_s if actor.respond_to?(:flipper_id)
            record_identity(actor)
          end

          def json_value(value)
            JSON.parse(JSON.generate(value))
          rescue JSON::GeneratorError, TypeError
            value.to_s
          end
        end

        runtime = PrGraphSeed.new(plan)
        result = runtime.run
        puts "#{RESULT_MARKER}" + JSON.generate(result)
        exit(result.fetch("status") == "succeeded" ? 0 : 1)
      RUBY
    end
  end
end
