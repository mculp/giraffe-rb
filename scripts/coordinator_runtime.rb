#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "time"
require_relative "artifact_log"
require_relative "event_log"
require_relative "failure_log"
require_relative "feedback_contract"
require_relative "github_feedback"
require_relative "ac_audit_contract"
require_relative "github_pr_ci"
require_relative "lineage_contract"
require_relative "outcome_contract"
require_relative "outcome_coverage"
require_relative "pr_ci_contract"
require_relative "repro_contract"
require_relative "spec_audit_contract"

module PrGraph
  class Coordinator
    class CoordinatorError < ContractError; end

    attr_reader :execution_path, :run_id, :session, :policy

    def initialize(execution_path:, run_id:, session:, policy_path: nil,
                   event_log: EventLog.new, artifact_log: ArtifactLog.new,
                   outcome_contract: OutcomeContract.new,
                   outcome_coverage: OutcomeCoverage.new,
                   repro_contract: ReproContract.new,
                   ac_audit_contract: AcAuditContract.new,
                   spec_audit_contract: SpecAuditContract.new,
                   pr_ci_contract: PrCiContract.new,
                   pr_ci_adapter: GitHubPrCi.new,
                   feedback_contract: FeedbackContract.new,
                   feedback_adapter: GitHubFeedback.new,
                   lineage_contract: nil, failure_log: nil)
      policy_path ||= File.expand_path("../references/coordinator-policy-v1.json", __dir__)
      @execution_path = File.expand_path(execution_path)
      @run_id = run_id
      @session = session
      @event_log = event_log
      @artifact_log = artifact_log
      @outcome_contract = outcome_contract
      @outcome_coverage = outcome_coverage
      @repro_contract = repro_contract
      @ac_audit_contract = ac_audit_contract
      @spec_audit_contract = spec_audit_contract
      @pr_ci_contract = pr_ci_contract
      @pr_ci_adapter = pr_ci_adapter
      @feedback_contract = feedback_contract
      @feedback_adapter = feedback_adapter
      @lineage_contract = lineage_contract || LineageContract.new(artifact_log: artifact_log)
      @failure_log = failure_log || FailureLog.new(execution_log: event_log)
      @policy = JSON.parse(File.read(policy_path))
      validate_identity!
      validate_policy!
    rescue JSON::ParserError => e
      raise CoordinatorError, "invalid coordinator policy: #{e.message}"
    end

    def start(node, worktree: nil, refresh: false)
      with_lock do
        state = load_state
        errors = start_errors(node, state, refresh: refresh)
        error!(errors.join("; ")) if errors.any?
        verify_done_gates!(state, current_candidate!(state)) if node == "DONE"

        attempt_id = SecureRandom.uuid
        lease_id = SecureRandom.uuid
        iteration = state.fetch("attempts").values.count { |attempt| attempt["node"] == node } + 1
        lease = build_lease(node, attempt_id, lease_id, worktree, state)
        lease_path = manifest_path(attempt_id, "lease")
        write_manifest!(lease_path, lease)

        begin
          @event_log.emit(
            execution_path,
            run_id: run_id,
            session: session,
            payload: {
              "e" => "node",
              "node" => node,
              "phase" => "start",
              "attempt_id" => attempt_id,
              "iteration" => iteration,
              "label" => "pg-#{node}"
            }
          )
        rescue StandardError
          cleanup_manifest(lease_path, lease)
          raise
        end

        {
          "node" => node,
          "attempt_id" => attempt_id,
          "iteration" => iteration,
          "lease_id" => lease_id,
          "authority" => lease.fetch("authority"),
          "worktree" => lease["worktree"]
        }
      end
    end

    def partial(node, attempt_id, note:)
      with_lock do
        state = load_state
        attempt = require_open_attempt!(state, node, attempt_id)
        @event_log.emit(
          execution_path,
          run_id: run_id,
          session: session,
          payload: {
            "e" => "node",
            "node" => node,
            "phase" => "partial",
            "attempt_id" => attempt_id,
            "iteration" => attempt.fetch("iteration"),
            "note" => note
          }
        )
      end
    end

    def wake(node, attempt_id, kind:, state:, wake_id: nil)
      with_lock do
        current = load_state
        require_open_attempt!(current, node, attempt_id)
        if state == "registered"
          error!("registered wake must not supply wake_id") if wake_id
          wake_id = SecureRandom.uuid
        else
          error!("#{state} wake requires wake_id") unless wake_id
        end
        event = @event_log.emit(
          execution_path,
          run_id: run_id,
          session: session,
          payload: {
            "e" => "wake",
            "node" => node,
            "attempt_id" => attempt_id,
            "wake_id" => wake_id,
            "kind" => kind,
            "state" => state
          }
        )
        event
      end
    end

    def complete(node, attempt_id, findings: 0, pr: nil, candidate_sha: nil, disposition: nil, cancel_live_wakes: false)
      with_lock do
        state = load_state
        attempt = require_open_attempt!(state, node, attempt_id)
        retired = retire_live_wakes!(state, attempt_id, cancel_live_wakes)
        persisted_result = state.dig("manifests", attempt_id, "result")
        if persisted_result && persisted_result.dig("recovery", "command") != "complete"
          error!("attempt #{attempt_id} has a persisted non-completion result")
        end
        lease = read_lease!(attempt_id)
        validate_lease_inputs!(node, lease, state)
        final_fingerprint = validate_mutation!(node, lease, allow_mutation: node == writer_node)
        if node == writer_node && persisted_result && persisted_result["final_fingerprint"] != final_fingerprint
          error!("persisted BUILD completion fingerprint does not match worktree")
        end
        head_sha = final_fingerprint && final_fingerprint.fetch("head")
        replay_legacy_build = node == writer_node && persisted_result && !build_review_output?(attempt_id, state)
        outputs = require_outputs!(node, attempt_id, state, head_sha: head_sha, replay_legacy_build: replay_legacy_build)
        validate_content_contract!(node, outputs, state, expected_pass: true, worktree: lease["worktree"])
        current_candidate = completion_candidate(node, outputs, state)

        if node == "PUBLISH"
          error!("PUBLISH completion requires --pr") unless pr.to_i.positive?
          error!("PUBLISH completion requires --candidate-sha") unless candidate_sha
          error!("PUBLISH candidate does not match current BUILD") unless candidate_sha == current_candidate
          publish = output_by_family!(outputs, "publish_manifest")
          @pr_ci_contract.validate_publish!(
            read_structured_artifact!(publish),
            artifact: publish,
            pr: pr,
            candidate_sha: candidate_sha
          )
        elsif pr || candidate_sha
          error!("--pr and --candidate-sha are valid only for PUBLISH")
        end

        verify_done_gates!(state, current_candidate) if node == "DONE"
        impact = persisted_result && persisted_result["outcome_impact"] || build_outcome_impact(
          node,
          attempt_id,
          outputs,
          state,
          polarity: "advanced"
        )
        outcome_disposition = if persisted_result
                                persisted_result["outcome_disposition"]
                              else
                                build_outcome_disposition(node, disposition, state)
                              end
        lifecycle = artifact_lifecycle_payloads(node, outputs, state, current_candidate)
        payloads = completion_payloads(
          node,
          attempt,
          findings: findings,
          pr: pr,
          candidate_sha: candidate_sha,
          current_candidate: current_candidate
        )
        result = completion_manifest(
          lease,
          state: "completed",
          final_fingerprint: final_fingerprint,
          recovery: completion_recovery(
            findings: findings,
            pr: pr,
            candidate_sha: candidate_sha,
            disposition: disposition
          ),
          outcome_impact: impact,
          outcome_disposition: outcome_disposition
        )
        write_manifest!(manifest_path(attempt_id, "result"), result)
        emit_artifact_links(lifecycle)
        @event_log.emit_many(execution_path, run_id: run_id, session: session, payloads: retired + payloads)
      end
    end

    def fail(node, attempt_id, reason:, findings: 1, failure_id:, revision:, cancel_live_wakes: false)
      with_lock do
        error!("BUILD failures do not grant another writer; keep the BUILD attempt open") if node == writer_node
        @failure_log.validate_identity!(failure_id, revision)
        state = load_state
        attempt = require_open_attempt!(state, node, attempt_id)
        retired = retire_live_wakes!(state, attempt_id, cancel_live_wakes)
        persisted_result = state.dig("manifests", attempt_id, "result")
        if persisted_result && persisted_result.dig("recovery", "command") != "fail"
          error!("attempt #{attempt_id} has a persisted non-failure result")
        end
        edge = [node, writer_node]
        error!("#{node} has no declared red edge to #{writer_node}") unless legal_edges.include?(edge)
        lease = read_lease!(attempt_id)
        validate_lease_inputs!(node, lease, state)
        final_fingerprint = validate_mutation!(node, lease, allow_mutation: true)
        changed = lease["fingerprint"] && final_fingerprint != lease["fingerprint"]
        reason = "#{reason}; unauthorized worktree mutation detected" if changed
        current_candidate = current_candidate!(state)
        outputs = require_outputs!(node, attempt_id, state, head_sha: final_fingerprint && final_fingerprint["head"])
        validate_content_contract!(node, outputs, state, expected_pass: false)
        impact = persisted_result && persisted_result["outcome_impact"] || build_outcome_impact(
          node,
          attempt_id,
          outputs,
          state,
          polarity: "contradicted"
        )
        lifecycle = artifact_lifecycle_payloads(node, outputs, state, current_candidate)
        stop_history = @failure_log.stop_history(
          processed_batches: state.dig("failure_queue", "processed"),
          failure_id: failure_id
        )
        failure_record = @failure_log.record(
          failure_path,
          execution_path: execution_path,
          run_id: run_id,
          session: session,
          finding: {
            "failure_id" => failure_id,
            "source_node" => node,
            "source_attempt_id" => attempt_id,
            "candidate_sha" => current_candidate,
            "revision" => revision,
            "reason" => reason,
            "artifact_ids" => outputs.map { |artifact| artifact.fetch("artifact_id") }
          },
          stop_history: stop_history
        )
        result = completion_manifest(
          lease,
          state: changed ? "mutation_violation" : "failed",
          final_fingerprint: final_fingerprint,
          recovery: {
            "command" => "fail",
            "reason" => reason,
            "findings" => findings,
            "failure_id" => failure_id,
            "revision" => revision
          },
          outcome_impact: impact,
          outcome_disposition: nil
        )
        payloads = []
        outcome_kind = node_policy(node).fetch("outcome_kind")
        if outcome_kind
          error!("failed quality node requires a positive finding count") unless findings.is_a?(Integer) && findings.positive?
          payloads << {
            "e" => "outcome",
            "kind" => outcome_kind,
            "attempt_id" => attempt_id,
            "pass" => false,
            "n" => findings
          }
        end
        edge_payload = {
          "e" => "edge",
          "from" => node,
          "to" => writer_node,
          "from_attempt_id" => attempt_id,
          "reason" => reason
        }
        edge_payload["finding_id"] = failure_id
        payloads << edge_payload
        payloads << {
          "e" => "node",
          "node" => node,
          "phase" => "done",
          "attempt_id" => attempt_id,
          "iteration" => attempt.fetch("iteration")
        }
        write_manifest!(manifest_path(attempt_id, "result"), result)
        emit_artifact_links(lifecycle)
        events = @event_log.emit_many(execution_path, run_id: run_id, session: session, payloads: retired + payloads)
        {"events" => events, "failure" => failure_record}
      end
    end

    # Saving is irreversible, so content is checked here, where a mistake can still be fixed, rather than
    # at finish, where a corrected second save would leave the attempt with two current outputs.
    def put_artifact(metadata, content, replaces: nil, reason: nil)
      error!("artifact metadata must be a JSON object") unless metadata.is_a?(Hash)
      with_lock do
        state = load_state
        @artifact_log.check(artifact_path, execution_path: execution_path, run_id: run_id, session: session,
                                           metadata: metadata, content: content)
        attempt_id, family = metadata.values_at("attempt_id", "family")
        attempt = state.fetch("attempts")[attempt_id]
        open = attempt && attempt["state"] == "open"
        error!("replace requires an open attempt") if replaces && !open
        if open
          existing = state.fetch("artifacts").select do |artifact|
            artifact["status"] == "current" && artifact["attempt_id"] == attempt_id && artifact["family"] == family
          end.map { |artifact| artifact.fetch("artifact_id") }
          if replaces
            error!("#{replaces} is not the current #{family} of attempt #{attempt_id}") unless existing.include?(replaces)
            error!("replace needs a reason") if reason.to_s.strip.empty?
          elsif existing.any?
            error!("attempt #{attempt_id} already has current #{family} #{existing.join(', ')}; save the correction with " \
                   "artifacts.rb replace <session> #{existing.first} <metadata> <content> --reason TEXT")
          end
          preflight_content!(family, metadata, content, state, attempt_id)
        end
        event = @artifact_log.store(artifact_path, execution_path: execution_path, run_id: run_id, session: session,
                                                  metadata: metadata, content: content)
        emit_artifact_links([artifact_link("supersedes", event.fetch("artifact_id"), replaces, reason)]) if replaces
        event
      end
    end

    # Recovers an attempt that already holds two current outputs of one family, recorded before put refused them.
    def supersede_duplicate(node, attempt_id, stale:, replacement:, reason:)
      error!("supersede needs a reason") if reason.to_s.strip.empty?
      with_lock do
        state = load_state
        require_open_attempt!(state, node, attempt_id)
        artifacts = state.fetch("artifacts").to_h { |artifact| [artifact.fetch("artifact_id"), artifact] }
        old, new = artifacts[stale], artifacts[replacement]
        error!("unknown artifact #{stale}") unless old
        error!("unknown artifact #{replacement}") unless new
        error!("an artifact cannot supersede itself") if stale == replacement
        [old, new].each do |artifact|
          error!("#{artifact['artifact_id']} is not current") unless artifact["status"] == "current"
          error!("#{artifact['artifact_id']} belongs to another attempt") unless artifact["attempt_id"] == attempt_id
        end
        error!("#{stale} and #{replacement} are different families") unless old["family"] == new["family"]
        error!("the replacement must be the newer artifact") unless new.fetch("seq") > old.fetch("seq")
        emit_artifact_links([artifact_link("supersedes", replacement, stale, reason)])
        {"superseded" => stale, "by" => replacement}
      end
    end

    # Cancels wakes left live on attempts that already closed. Completion refuses to leave a live wake
    # behind, so this only recovers runs recorded before that rule, where a stranded wake blocks DONE.
    def reap_wakes(reason:)
      error!("reap-wakes needs a reason") if reason.to_s.strip.empty?
      with_lock do
        state = load_state
        stranded = state.fetch("wakes").values.select do |wake|
          LIVE_WAKE_STATES.include?(wake["state"]) && state.dig("attempts", wake["attempt_id"], "state") == "closed"
        end
        payloads = wake_retirement_payloads(stranded, reason)
        events = payloads.empty? ? [] : @event_log.emit_many(execution_path, run_id: run_id, session: session, payloads: payloads)
        {"reaped" => stranded.map { |wake| wake.fetch("wake_id") }, "events" => events}
      end
    end

    def resume(worktree: nil, offline: false)
      with_lock do
        state = load_state
        resume_projection(state, worktree: worktree, offline: offline)
      end
    end

    def check(worktree: nil, offline: false)
      with_lock do
        state = load_state
        lost_wakes = state.fetch("attempts").values.select do |attempt|
          attempt["state"] == "open" && node_policy(attempt["node"]).fetch("wait_node") &&
            state.fetch("wakes").values.none? do |wake|
              wake["attempt_id"] == attempt["attempt_id"] && wake["state"] == "armed"
            end
        end
        if lost_wakes.any?
          error!("open gate(s) have no armed wake source: #{lost_wakes.map { |attempt| attempt['node'] }.join(', ')}")
        end

        runnable, = runnable_nodes(state)
        open_attempts = state.fetch("attempts").values.select { |attempt| attempt["state"] == "open" }
        if !state.fetch("terminal") && runnable.empty? && open_attempts.empty?
          error!("run is stalled: no runnable node, open attempt, or terminal DONE")
        end
        resume_projection(state, worktree: worktree, offline: offline)
      end
    end

    # Validated local projection without contacting GitHub or requiring the old worktree.
    # Used by the harness and by Store before installing a recovered run.
    def snapshot
      with_lock { load_state }
    end

    def read_view
      with_lock do
        state = load_state
        projection = begin
          resume_projection(state, worktree: nil, offline: true)
        rescue CoordinatorError => error
          # A UI must still explain a paused mutation violation. This view grants no transitions;
          # start/check/complete retain their normal checks.
          {"current_candidate" => current_candidate(state), "terminal" => state.fetch("terminal"),
           "runnable" => [], "blocked" => policy.fetch("nodes").keys.to_h { |node| [node, [error.message]] },
           "validation_error" => error.message}
        end
        {"state" => state, "projection" => projection}
      end
    end

    # The contract checks `complete` applies to a passing VERIFY, for a caller deciding pass or fail before
    # it saves the evidence. Raises a ContractError where `complete` would refuse.
    def validate_verification!(verification, worktree:)
      with_lock { validate_verification(verification, load_state, worktree) }
    end

    private

    def error!(message)
      raise CoordinatorError, message
    end

    def artifact_path
      execution_path.sub(/\.jsonl\z/, ".artifacts.jsonl")
    end

    def failure_path
      execution_path.sub(/\.jsonl\z/, ".failures.jsonl")
    end

    def coordinator_dir
      execution_path.sub(/\.jsonl\z/, ".coordinator")
    end

    def manifest_path(attempt_id, kind)
      File.join(coordinator_dir, "#{attempt_id}.#{kind}.json")
    end

    def writer_node
      policy.fetch("writer_node")
    end

    def legal_edges
      @legal_edges ||= @event_log.contract.fetch("graph").fetch("legal_edges")
    end

    def node_policy(node)
      policy.fetch("nodes")[node] || error!("unknown coordinator node #{node}")
    end

    def validate_identity!
      error!("execution log path must end in .jsonl") unless execution_path.end_with?(".jsonl")
      error!("invalid run identity") unless run_id.match?(EventLog::UUID)
      error!("invalid conversation identity") unless session.match?(EventLog::SESSION)
    end

    def validate_policy!
      error!("coordinator_policy_version must be 1") unless policy["coordinator_policy_version"] == 1
      error!("coordinator policy execution version mismatch") unless policy["execution_contract_version"] == @event_log.version
      error!("coordinator policy artifact version mismatch") unless policy["artifact_contract_version"] == @artifact_log.version
      nodes = @event_log.contract.fetch("graph").fetch("nodes")
      error!("coordinator policy nodes do not match execution graph") unless policy.fetch("nodes").keys.sort == nodes.sort
      error!("writer node must be BUILD") unless writer_node == "BUILD"
      policy.fetch("nodes").each do |node, rules|
        %w[inputs outputs mutation_guard wait_node outcome_kind].each do |field|
          error!("#{node} policy is missing #{field}") unless rules.key?(field)
        end
        (rules.fetch("inputs") + rules.fetch("outputs")).each do |artifact_rule|
          family = @artifact_log.contract.fetch("families")[artifact_rule["family"]]
          error!("#{node} policy names unknown artifact family #{artifact_rule['family']}") unless family
          error!("#{artifact_rule['family']} cannot belong to #{node}") if rules.fetch("outputs").include?(artifact_rule) && !family.fetch("nodes").include?(node)
          error!("invalid candidate policy for #{node}") unless %w[any current head].include?(artifact_rule["candidate"])
        end
        kind = rules["outcome_kind"]
        if kind && EventLog::OUTCOME_NODE[kind] != node
          error!("#{node} has invalid outcome kind #{kind}")
        end
      end
      policy.fetch("nodes").each do |node, rules|
        successor = rules["introduced_before"]
        next unless successor

        error!("#{node} introduced_before names unknown node #{successor}") unless policy.fetch("nodes").key?(successor)
        error!("#{successor} must depend on introduced node #{node}") unless dependencies(successor).include?(node)
        error!("introduced node #{node} cannot be the writer") if node == writer_node
      end
      policy.fetch("nodes").each do |node, rules|
        next unless rules["retired"]

        error!("retired node #{node} cannot be the writer") if node == writer_node
        dependents = policy.fetch("nodes").keys.select { |other| dependencies(other).include?(node) }
        error!("retired node #{node} still gates #{dependents.join(', ')}") if dependents.any?
      end
    end

    def with_lock
      FileUtils.mkdir_p(coordinator_dir, mode: 0o700)
      File.open("#{execution_path}.coordinator.lock", File::WRONLY | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def load_state
      events = @event_log.validate_file!(execution_path)
      error!("run identity does not match active state") unless events.first["run_id"] == run_id
      error!("conversation identity does not match active state") unless events.first["session"] == session
      artifact_events = @artifact_log.read(artifact_path, allow_empty: true)
      artifact_projection = @artifact_log.validate_sequence!(
        artifact_events,
        execution_events: events,
        artifact_path: artifact_path
      )
      artifact_statuses = artifact_projection.fetch("artifacts").to_h do |artifact|
        [artifact.fetch("artifact_id"), artifact.fetch("status")]
      end
      artifacts = artifact_events.each_with_object([]) do |event, collected|
        next unless event["e"] == "artifact"

        collected << event.merge("status" => artifact_statuses.fetch(event.fetch("artifact_id")))
      end
      attempts = {}
      outcomes = Hash.new { |hash, key| hash[key] = [] }
      wakes = {}
      edges = []
      published = nil
      terminal = false
      events.each do |event|
        case event["e"]
        when "node"
          attempt = attempts[event["attempt_id"]] ||= {
            "attempt_id" => event["attempt_id"],
            "node" => event["node"],
            "iteration" => event["iteration"],
            "label" => event["label"],
            "state" => "open",
            "start_seq" => event["seq"]
          }
          if event["phase"] == "done"
            attempt["state"] = "closed"
            attempt["done_seq"] = event["seq"]
          end
        when "outcome"
          outcomes[event["attempt_id"]] << event
        when "edge"
          edges << event
        when "wake"
          wakes[event["wake_id"]] = event
        when "publish"
          published = event
        when "done"
          terminal = true
        end
      end
      state = {
        "events" => events,
        "attempts" => attempts,
        "outcomes" => outcomes,
        "wakes" => wakes,
        "edges" => edges,
        "published" => published,
        "terminal" => terminal,
        "artifacts" => artifacts
      }
      state["manifests"] = load_attempt_manifests!(state.fetch("attempts"))
      state["outcome_context"] = outcome_context(state)
      state["outcome_coverage"] = @outcome_coverage.project!(
        clauses: state.dig("outcome_context", "clauses"),
        attempts: state.fetch("attempts"),
        manifests: state.fetch("manifests"),
        artifacts: state.fetch("artifacts"),
        planned_uncovered: state.dig("outcome_context", "planned_uncovered")
      )
      failure_projection = @failure_log.validate_file!(failure_path, execution_events: events)
      state["failure_queue"] = project_failure_queue(state, failure_projection)
      state
    end

    def start_errors(node, state, refresh: false)
      rules = node_policy(node)
      return ["#{node} is retired; its work runs inside BUILD"] if retired_for_run?(node, state)
      return ["#{node} was introduced after this run passed #{node_policy(node)['introduced_before']}"] if introduced_after_run?(node, state)

      errors = []
      errors << "--refresh is valid only for BOT-FEEDBACK" if refresh && node != "BOT-FEEDBACK"
      errors << "run is already terminal" if state.fetch("terminal")
      if state.dig("failure_queue", "stopped")
        stops = state.dig("failure_queue", "stops").map { |stop| stop["failure_id"] }.uniq
        errors << "run stopped by recurring failure(s): #{stops.join(', ')}"
      end
      open_attempts = state.fetch("attempts").values.select { |attempt| attempt["state"] == "open" }
      errors << "#{node} already has an open attempt" if open_attempts.any? { |attempt| attempt["node"] == node }
      if node == writer_node
        guarded = open_attempts.select { |attempt| node_policy(attempt["node"]).fetch("mutation_guard") }
        errors << "writer contention with open lane(s): #{guarded.map { |attempt| attempt['node'] }.join(', ')}" if guarded.any?
      elsif rules.fetch("mutation_guard") && open_attempts.any? { |attempt| attempt["node"] == writer_node }
        errors << "reader cannot start while BUILD holds mutation authority"
      end
      if node == "DONE"
        others = open_attempts.reject { |attempt| attempt["node"] == "DONE" }
        errors << "DONE requires all other attempts to be closed" if others.any?
      end

      latest_done = latest_done_by_node(state)
      run_dependencies = run_dependencies(node, state)
      run_dependencies.each do |dependency|
        errors << "dependency #{dependency} is incomplete" unless latest_done[dependency]
      end
      previous = latest_done[node]
      if refresh && node == "BOT-FEEDBACK"
        evidence = current_artifacts(state, "bot_feedback", candidate: "current")
        unless previous && evidence.one? && artifact_passes?(evidence.first, state)
          errors << "BOT-FEEDBACK refresh requires current green feedback evidence"
        end
      end
      if previous
        if node == writer_node
          errors << "BUILD has no queued failures" if state.dig("failure_queue", "pending").empty?
        elsif !(refresh && node == "BOT-FEEDBACK") && run_dependencies.all? { |dependency| latest_done[dependency] } &&
              run_dependencies.none? { |dependency| latest_done[dependency]["done_seq"] > previous["done_seq"] }
          errors << "#{node} is already current"
        end
      end
      errors.concat(input_errors(node, state)) if errors.none? { |message| message.start_with?("dependency") }
      errors
    rescue CoordinatorError => e
      [e.message]
    end

    def retired_for_run?(node, state)
      return false unless node_policy(node)["retired"]
      return true unless node == "SELF-REVIEW"

      builds = current_artifacts(state, "build_manifest")
      return true unless builds.one?

      attempt_id = builds.first.fetch("attempt_id")
      return true unless state.dig("attempts", attempt_id, "state") == "closed"

      build_review_output?(attempt_id, state)
    end

    # A node added to the graph is skipped for a run that started its successor without it. The
    # successor depends on the node, so only a run recorded before the node existed can do that;
    # it resumes, even mid-attempt, without re-planning.
    def introduced_after_run?(node, state)
      successor = node_policy(node)["introduced_before"]
      return false unless successor

      attempts = state.fetch("attempts").values
      attempts.none? { |attempt| attempt["node"] == node } &&
        attempts.any? { |attempt| attempt["node"] == successor }
    end

    def skipped_for_run?(node, state)
      retired_for_run?(node, state) || introduced_after_run?(node, state)
    end

    def run_dependencies(node, state)
      dependencies(node).reject { |dependency| skipped_for_run?(dependency, state) }
    end

    def build_review_output?(attempt_id, state)
      state.fetch("artifacts").any? do |artifact|
        artifact["attempt_id"] == attempt_id && artifact["family"] == "self_review"
      end
    end

    def load_attempt_manifests!(attempts)
      attempts.each_with_object({}) do |(attempt_id, attempt), manifests|
        next unless attempt["label"] == "pg-#{attempt['node']}"

        lease = read_manifest_json!(manifest_path(attempt_id, "lease"), "coordinator lease")
        unless lease["coordinator_policy_version"] == policy.fetch("coordinator_policy_version") &&
               lease["run_id"] == run_id && lease["session"] == session &&
               lease["node"] == attempt["node"] && lease["attempt_id"] == attempt_id &&
               lease["lease_id"].is_a?(String) && lease["lease_id"].match?(EventLog::UUID)
          error!("coordinator lease identity mismatch for #{attempt_id}")
        end
        expected_authority = attempt["node"] == writer_node ? "write" : "read"
        error!("coordinator lease authority mismatch for #{attempt_id}") unless lease["authority"] == expected_authority
        error!("coordinator lease inputs are missing") unless lease["inputs"].is_a?(Array)
        if node_policy(attempt["node"]).fetch("mutation_guard")
          error!("protected attempt lease is missing worktree state") unless lease["worktree"].is_a?(String) && lease["fingerprint"].is_a?(Hash)
        end

        result_path = manifest_path(attempt_id, "result")
        result = File.file?(result_path) ? read_manifest_json!(result_path, "coordinator result") : nil
        error!("completed attempt #{attempt_id} is missing its result manifest") if attempt["state"] == "closed" && !result
        if attempt["state"] == "open" && result && !result["recovery"]
          error!("interrupted result #{attempt_id} is missing exact recovery arguments")
        end
        if result
          unless result["coordinator_policy_version"] == policy.fetch("coordinator_policy_version") &&
                 result["run_id"] == run_id && result["session"] == session &&
                 result["node"] == attempt["node"] && result["attempt_id"] == attempt_id &&
                 result["lease_id"] == lease["lease_id"] &&
                 %w[completed failed mutation_violation].include?(result["state"])
            error!("coordinator result identity mismatch for #{attempt_id}")
          end
          validate_result_recovery!(result, attempt_id)
        end
        manifests[attempt_id] = {"lease" => lease, "result" => result}
      end
    end

    def read_manifest_json!(path, label)
      error!("missing #{label} at #{path}") unless File.file?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      error!("corrupt #{label}: #{e.message}")
    end

    def validate_result_recovery!(result, attempt_id)
      recovery = result["recovery"]
      return unless recovery

      error!("coordinator result recovery is invalid for #{attempt_id}") unless recovery.is_a?(Hash)
      command = recovery["command"]
      expected = result["state"] == "completed" ? "complete" : "fail"
      error!("coordinator result recovery command mismatch for #{attempt_id}") unless command == expected
      error!("coordinator result recovery findings are invalid for #{attempt_id}") unless recovery["findings"].is_a?(Integer) && recovery["findings"] >= 0
      if command == "complete"
        allowed = %w[command findings pr candidate_sha disposition]
        error!("coordinator result completion recovery has unknown fields for #{attempt_id}") unless (recovery.keys - allowed).empty?
        if result["node"] == "PUBLISH"
          unless recovery["pr"].is_a?(Integer) && recovery["pr"].positive? &&
                 recovery["candidate_sha"].is_a?(String) && recovery["candidate_sha"].match?(EventLog::GIT_SHA)
            error!("coordinator result publish recovery is incomplete for #{attempt_id}")
          end
        elsif recovery.key?("pr") || recovery.key?("candidate_sha")
          error!("coordinator result recovery carries publish arguments for #{attempt_id}")
        end
        if result["node"] == "DONE"
          error!("coordinator result DONE recovery is missing disposition") unless recovery["disposition"].is_a?(Hash)
        elsif recovery.key?("disposition")
          error!("coordinator result recovery carries DONE disposition for #{attempt_id}")
        end
        return
      end

      required = %w[reason failure_id revision]
      allowed = %w[command reason findings failure_id revision]
      error!("coordinator result failure recovery has unknown fields for #{attempt_id}") unless (recovery.keys - allowed).empty?
      unless required.all? { |field| recovery[field].is_a?(String) && !recovery[field].empty? }
        error!("coordinator result failure recovery is incomplete for #{attempt_id}")
      end
      error!("coordinator result failure findings are invalid for #{attempt_id}") unless recovery["findings"].positive?
      @failure_log.validate_identity!(recovery.fetch("failure_id"), recovery.fetch("revision"))
    end

    def dependencies(node)
      @event_log.contract.fetch("graph").fetch("dependencies").fetch(node)
    end

    def latest_done_by_node(state)
      state.fetch("attempts").values.select { |attempt| attempt["state"] == "closed" }.each_with_object({}) do |attempt, latest|
        current = latest[attempt["node"]]
        latest[attempt["node"]] = attempt if !current || attempt.fetch("done_seq") > current.fetch("done_seq")
      end
    end

    def current_artifacts(state, family, candidate: "any")
      artifacts = state.fetch("artifacts").select do |artifact|
        artifact["status"] == "current" && artifact["family"] == family
      end
      if candidate == "current"
        sha = current_candidate!(state)
        artifacts = artifacts.select { |artifact| artifact["candidate_sha"] == sha }
      end
      artifacts
    end

    def input_errors(node, state)
      node_policy(node).fetch("inputs").flat_map do |rule|
        producers = @artifact_log.contract.fetch("families").fetch(rule.fetch("family")).fetch("nodes")
        next [] if producers.all? { |producer| skipped_for_run?(producer, state) }

        artifacts = current_artifacts(state, rule.fetch("family"), candidate: rule.fetch("candidate"))
        if artifacts.empty?
          ["missing current input artifact #{rule['family']}"]
        elsif artifacts.length != 1
          ["conflicting current input artifacts for #{rule['family']}"]
        elsif (rule["pass_required"] || artifacts.first["node"] == "SELF-REVIEW") && !artifact_passes?(artifacts.first, state)
          ["input artifact #{rule['family']} is not green"]
        else
          []
        end
      end
    end

    def input_artifact_snapshot(node, state)
      node_policy(node).fetch("inputs").flat_map do |rule|
        current_artifacts(state, rule.fetch("family"), candidate: rule.fetch("candidate")).map do |artifact|
          artifact.slice("artifact_id", "family", "input_sha", "candidate_sha", "content_sha256")
        end
      end.sort_by { |artifact| [artifact.fetch("family"), artifact.fetch("artifact_id")] }
    end

    def validate_lease_inputs!(node, lease, state)
      current = input_artifact_snapshot(node, state)
      error!("input artifact set changed while #{node} was running") unless lease.fetch("inputs") == current
    end

    def artifact_passes?(artifact, state)
      return false unless state.dig("attempts", artifact["attempt_id"], "state") == "closed"

      outcomes = state.fetch("outcomes").fetch(artifact["attempt_id"], [])
      outcomes.length == 1 && outcomes.first["pass"] == true
    end

    def current_candidate(state)
      manifests = current_artifacts(state, "build_manifest")
      manifests.one? ? manifests.first["candidate_sha"] : nil
    end

    def current_candidate!(state)
      candidate = current_candidate(state)
      error!("current BUILD candidate is missing or conflicting") unless candidate
      candidate
    end

    PREFLIGHT_FAMILIES = %w[triage_brief repro_report verification].freeze

    def preflight_content!(family, metadata, content, state, attempt_id)
      return unless PREFLIGHT_FAMILIES.include?(family)

      error!("#{family} must use application/json content") unless metadata["content_type"] == "application/json"
      begin
        doc = JSON.parse(content.to_s)
      rescue JSON::ParserError => e
        error!("#{family} content is invalid JSON: #{e.message}")
      end
      error!("#{family} content must be a JSON object") unless doc.is_a?(Hash)
      return @outcome_contract.validate_register!(doc) if family == "triage_brief"

      triage = current_artifacts(state, "triage_brief")
      return unless triage.one?

      clause_ids = @outcome_contract.validate_register!(read_structured_artifact!(triage.first)).fetch("clause_ids")
      if family == "repro_report"
        @repro_contract.validate_report!(doc, clause_ids: clause_ids, input_sha: metadata["input_sha"])
        return
      end
      candidate = metadata["candidate_sha"]
      @ac_audit_contract.validate_shape!(doc, clause_ids: clause_ids, candidate_sha: candidate) if doc.key?("ac_audit")
      if doc.key?("spec_audit")
        worktree = read_lease!(attempt_id)["worktree"]
        base = spec_audit_base(state)
        @spec_audit_contract.validate_shape!(
          doc, candidate_sha: candidate, base_sha: base,
               spec_paths: worktree && base && SpecAuditContract.changed_spec_paths(worktree, base, candidate)
        )
      end
      return unless doc.key?("regression")

      repro = current_artifacts(state, "repro_report")
      return unless repro.one?

      report = read_structured_artifact!(repro.first)
      worktree = read_lease!(attempt_id)["worktree"]
      return unless report["status"] == "reproduced" && worktree

      changed = git_capture(worktree, "diff", "--name-only", report.fetch("base_sha"), candidate).split("\n")
      @repro_contract.validate_regression!(report, doc, candidate_sha: candidate, changed_paths: changed, strict: false)
    end

    LIVE_WAKE_STATES = %w[registered armed].freeze

    # A closed attempt can never touch its wakes again, so a live one left behind would block DONE forever.
    def retire_live_wakes!(state, attempt_id, cancel)
      live = state.fetch("wakes").values.select do |wake|
        wake["attempt_id"] == attempt_id && LIVE_WAKE_STATES.include?(wake["state"])
      end
      return [] if live.empty?

      ids = live.map { |wake| "#{wake['wake_id']} (#{wake['state']})" }.join(", ")
      unless cancel
        error!("attempt #{attempt_id} still has live wake(s) #{ids}; send each to fired, cancelled, or expired, or pass --cancel-live-wakes")
      end
      wake_retirement_payloads(live, "cancelled when attempt #{attempt_id} closed")
    end

    def wake_retirement_payloads(wakes, note)
      wakes.flat_map do |wake|
        base = wake.slice("node", "attempt_id", "wake_id", "kind").merge("e" => "wake", "note" => note)
        (wake["state"] == "registered" ? %w[armed cancelled] : %w[cancelled]).map { |step| base.merge("state" => step) }
      end
    end

    def require_open_attempt!(state, node, attempt_id)
      node_policy(node)
      attempt = state.fetch("attempts")[attempt_id]
      error!("unknown attempt #{attempt_id}") unless attempt
      error!("attempt #{attempt_id} belongs to #{attempt['node']}, not #{node}") unless attempt["node"] == node
      error!("attempt #{attempt_id} is already closed") unless attempt["state"] == "open"
      attempt
    end

    def require_outputs!(node, attempt_id, state, head_sha: nil, replay_legacy_build: false)
      rules = node_policy(node).fetch("outputs")
      rules = rules.reject { |rule| rule["family"] == "self_review" } if replay_legacy_build
      rules.map do |rule|
        artifacts = state.fetch("artifacts").select do |artifact|
          artifact["status"] == "current" && artifact["family"] == rule["family"] &&
            artifact["attempt_id"] == attempt_id
        end
        error!("#{node} attempt requires one current #{rule['family']} output") unless artifacts.one?
        artifact = artifacts.first
        @lineage_contract.validate_artifact!(artifact)
        expected = case rule.fetch("candidate")
                   when "head" then head_sha
                   when "current" then current_candidate!(state)
                   end
        if expected && artifact["candidate_sha"] != expected
          error!("#{rule['family']} candidate does not match #{rule['candidate']}")
        end
        artifact
      end
    end

    def validate_content_contract!(node, outputs, state, expected_pass: nil, worktree: nil)
      case node
      when "TRIAGE"
        triage = output_by_family!(outputs, "triage_brief")
        @outcome_contract.validate_register!(read_structured_artifact!(triage))
      when "REPRODUCE"
        triage = current_artifacts(state, "triage_brief").first
        error!("REPRODUCE requires exactly one current triage_brief") unless triage
        repro = output_by_family!(outputs, "repro_report")
        register = @outcome_contract.validate_register!(read_structured_artifact!(triage))
        @repro_contract.validate_report!(
          read_structured_artifact!(repro),
          clause_ids: register.fetch("clause_ids"),
          input_sha: repro.fetch("input_sha")
        )
      when "PLAN"
        triage = current_artifacts(state, "triage_brief").first
        error!("PLAN requires exactly one current triage_brief") unless triage
        implementation = read_structured_artifact!(output_by_family!(outputs, "implementation_plan"))
        test_plan = read_structured_artifact!(output_by_family!(outputs, "test_plan"))
        @outcome_contract.validate_plan!(read_structured_artifact!(triage), implementation, test_plan)
        if policy.fetch("nodes").key?("REPRODUCE") && !skipped_for_run?("REPRODUCE", state)
          repro = current_artifacts(state, "repro_report")
          error!("PLAN requires exactly one current repro_report") unless repro.one?
          @repro_contract.validate_plan!(read_structured_artifact!(repro.first), implementation, test_plan)
        end
      when "VERIFY"
        if expected_pass
          validate_verification(read_structured_artifact!(output_by_family!(outputs, "verification")), state, worktree)
        end
      when "PUBLISH"
        publish = output_by_family!(outputs, "publish_manifest")
        @pr_ci_contract.validate_publish!(read_structured_artifact!(publish), artifact: publish)
      when "CI-WATCH"
        ci = output_by_family!(outputs, "ci_result")
        @pr_ci_contract.validate_ci!(
          read_structured_artifact!(ci),
          artifact: ci,
          expected_pass: expected_pass
        )
      when "BOT-FEEDBACK"
        feedback = output_by_family!(outputs, "bot_feedback")
        @feedback_contract.validate!(
          read_structured_artifact!(feedback),
          artifact: feedback,
          expected_pass: expected_pass
        )
      end
    end

    def validate_verification(verification, state, worktree)
      validate_ac_audit!(verification, state)
      validate_spec_audit!(verification, state, worktree)
      validate_regression!(verification, state, worktree)
    end

    def validate_ac_audit!(verification, state)
      triage = current_artifacts(state, "triage_brief")
      error!("VERIFY requires exactly one current triage_brief") unless triage.one?
      register = @outcome_contract.validate_register!(read_structured_artifact!(triage.first))
      @ac_audit_contract.validate!(
        verification,
        clause_ids: register.fetch("clause_ids"),
        candidate_sha: current_candidate!(state)
      )
    end

    def validate_spec_audit!(verification, state, worktree)
      error!("VERIFY spec_audit needs the attempt's worktree") unless worktree
      base = spec_audit_base(state)
      error!("VERIFY spec_audit needs a current repro_report or worktree_manifest to derive the base") unless base
      candidate = current_candidate!(state)
      @spec_audit_contract.validate!(
        verification,
        candidate_sha: candidate, base_sha: base,
        spec_paths: SpecAuditContract.changed_spec_paths(worktree, base, candidate)
      )
    end

    # The run's own base, so an auditor cannot shrink its scope by choosing one: REPRODUCE records it, and
    # runs recorded before REPRODUCE fall back to the commit WORKTREE started from.
    def spec_audit_base(state)
      repro = current_artifacts(state, "repro_report")
      return read_structured_artifact!(repro.first)["base_sha"] if repro.one?

      worktree = current_artifacts(state, "worktree_manifest")
      worktree.first["input_sha"] if worktree.one?
    end

    def validate_regression!(verification, state, worktree)
      return unless policy.fetch("nodes").key?("REPRODUCE") && !skipped_for_run?("REPRODUCE", state)

      repro = current_artifacts(state, "repro_report")
      error!("VERIFY requires exactly one current repro_report") unless repro.one?
      report = read_structured_artifact!(repro.first)
      return unless report.fetch("status") == "reproduced"

      candidate = current_candidate!(state)
      changed = git_capture(worktree, "diff", "--name-only", report.fetch("base_sha"), candidate).split("\n")
      @repro_contract.validate_regression!(
        report,
        verification,
        candidate_sha: candidate,
        changed_paths: changed
      )
    end

    def output_by_family!(outputs, family)
      output = outputs.find { |artifact| artifact["family"] == family }
      error!("missing #{family} output") unless output
      output
    end

    def read_structured_artifact!(artifact)
      @outcome_contract.read_artifact!(artifact, artifact_path: artifact_path)
    end

    def outcome_context(state)
      triage = current_artifacts(state, "triage_brief")
      return {"clauses" => [], "planned_uncovered" => []} if triage.empty?
      error!("outcome coverage requires exactly one current triage brief") unless triage.one?

      triage_content = read_structured_artifact!(triage.first)
      register = @outcome_contract.validate_register!(triage_content)
      context = {
        "clauses" => register.fetch("clause_ids"),
        "planned_uncovered" => []
      }
      implementation = current_artifacts(state, "implementation_plan")
      test_plan = current_artifacts(state, "test_plan")
      return context if implementation.empty? && test_plan.empty?
      # PLAN saves its two artifacts one at a time; until its attempt closes, one without the other is expected.
      partial = (implementation + test_plan).all? { |artifact| state.dig("attempts", artifact["attempt_id"], "state") == "open" }
      return context if partial && !(implementation.one? && test_plan.one?)
      unless implementation.one? && test_plan.one?
        error!("outcome coverage requires one current implementation plan and test plan")
      end

      plan = @outcome_contract.validate_plan!(
        triage_content,
        read_structured_artifact!(implementation.first),
        read_structured_artifact!(test_plan.first)
      )
      context["planned_uncovered"] = plan.fetch("uncovered_outcome_ids")
      context
    end

    def build_outcome_impact(node, attempt_id, outputs, state, polarity:)
      context = state.fetch("outcome_context")
      @outcome_coverage.build_impact!(
        node: node,
        attempt_id: attempt_id,
        outputs: outputs,
        clauses: context.fetch("clauses"),
        prior: state.fetch("outcome_coverage"),
        polarity: polarity
      )
    end

    def build_outcome_disposition(node, requested, state)
      if node != "DONE"
        error!("outcome disposition is valid only for DONE") if requested
        return nil
      end

      context = state.fetch("outcome_context")
      @outcome_coverage.finalize!(
        requested,
        clauses: context.fetch("clauses"),
        projection: state.fetch("outcome_coverage"),
        planned_uncovered: context.fetch("planned_uncovered")
      )
    end

    def completion_candidate(node, outputs, state)
      if node == writer_node
        outputs.first.fetch("candidate_sha") || error!("BUILD output is missing candidate SHA")
      else
        current_candidate(state)
      end
    end

    def completion_payloads(node, attempt, findings:, pr:, candidate_sha:, current_candidate:)
      payloads = []
      outcome_kind = node_policy(node).fetch("outcome_kind")
      if outcome_kind
        error!("findings must be a non-negative integer") unless findings.is_a?(Integer) && findings >= 0
        payloads << {
          "e" => "outcome",
          "kind" => outcome_kind,
          "attempt_id" => attempt.fetch("attempt_id"),
          "pass" => true,
          "n" => findings
        }
      elsif findings != 0
        error!("findings are valid only for a quality node")
      end
      if node == "PUBLISH"
        payloads << {"e" => "publish", "pr" => pr.to_i, "candidate_sha" => candidate_sha}
      end
      payloads << {
        "e" => "node",
        "node" => node,
        "phase" => "done",
        "attempt_id" => attempt.fetch("attempt_id"),
        "iteration" => attempt.fetch("iteration")
      }
      payloads << {"e" => "done", "candidate_sha" => current_candidate} if node == "DONE"
      payloads
    end

    def artifact_lifecycle_payloads(node, outputs, state, candidate)
      source_ids = outputs.map { |artifact| artifact["artifact_id"] }
      payloads = []
      superseded_ids = []
      outputs.each do |source|
        state.fetch("artifacts").each do |target|
          next unless target["status"] == "current"
          next if source_ids.include?(target["artifact_id"])
          next unless target["family"] == source["family"] && target["node"] == source["node"]

          payloads << artifact_link("supersedes", source["artifact_id"], target["artifact_id"], "new #{node} attempt output")
          superseded_ids << target["artifact_id"]
        end
      end
      if node == @lineage_contract.trigger_node
        build_review = outputs.find { |artifact| artifact["family"] == "self_review" }
        state.fetch("artifacts").each do |target|
          next unless target["status"] == "current" && @lineage_contract.candidate_dependent?(target["family"])
          next if superseded_ids.include?(target["artifact_id"])
          if build_review && target["family"] == "self_review" && target["node"] == "SELF-REVIEW"
            payloads << artifact_link("invalidates", build_review["artifact_id"], target["artifact_id"], "BUILD supplies current review evidence")
            next
          end
          next if target["candidate_sha"] == candidate

          source = output_by_family!(outputs, @lineage_contract.source_family)
          payloads << artifact_link("invalidates", source["artifact_id"], target["artifact_id"], "BUILD changed candidate SHA")
        end
      end
      payloads
    end

    def artifact_link(relation, source, target, reason)
      {
        "e" => "link",
        "link_id" => SecureRandom.uuid,
        "relation" => relation,
        "from_artifact_id" => source,
        "to_artifact_id" => target,
        "reason" => reason
      }
    end

    def emit_artifact_links(payloads)
      return if payloads.empty?

      @artifact_log.emit_many(
        artifact_path,
        execution_path: execution_path,
        run_id: run_id,
        session: session,
        payloads: payloads
      )
    end

    def project_failure_queue(state, failure_projection)
      findings = failure_projection.fetch("findings")
      artifacts = state.fetch("artifacts").to_h { |artifact| [artifact.fetch("artifact_id"), artifact] }
      findings.each do |finding|
        finding.fetch("artifact_ids").each do |artifact_id|
          artifact = artifacts[artifact_id]
          error!("failure references unknown evidence artifact #{artifact_id}") unless artifact
          unless artifact["attempt_id"] == finding["source_attempt_id"] && artifact["node"] == finding["source_node"]
            error!("failure evidence does not belong to its source attempt")
          end
          unless artifact["candidate_sha"] == finding["candidate_sha"]
            error!("failure evidence candidate does not match the finding")
          end
        end
      end
      by_occurrence = findings.to_h { |finding| [finding.fetch("occurrence_id"), finding] }
      claimed = {}
      batch_ids = {}
      batches = state.fetch("attempts").values.select { |attempt| attempt["node"] == writer_node }.each_with_object([]) do |attempt, collected|
        manifest = state.fetch("manifests")[attempt.fetch("attempt_id")]
        next unless manifest

        lease = manifest.fetch("lease")
        batch = lease["failure_batch"]
        next unless batch

        validate_failure_batch!(batch, by_occurrence)
        error!("duplicate failure batch id #{batch['batch_id']}") if batch_ids[batch["batch_id"]]
        batch_ids[batch["batch_id"]] = true
        occurrence_ids = batch.fetch("failures").flat_map { |failure| failure.fetch("occurrence_ids") }
        occurrence_ids.each do |occurrence_id|
          error!("failure occurrence #{occurrence_id} was claimed twice") if claimed[occurrence_id]
          claimed[occurrence_id] = batch["batch_id"]
        end
        collected << batch.merge(
          "build_attempt_id" => attempt.fetch("attempt_id"),
          "state" => attempt.fetch("state") == "open" ? "processing" : "processed",
          "done_seq" => attempt["done_seq"]
        )
      end
      pending = findings.reject { |finding| claimed.key?(finding.fetch("occurrence_id")) }
      {
        "findings" => findings,
        "pending" => pending,
        "processing" => batches.select { |batch| batch["state"] == "processing" },
        "processed" => batches.select { |batch| batch["state"] == "processed" },
        "stops" => failure_projection.fetch("stops"),
        "stopped" => failure_projection.fetch("stopped")
      }
    end

    def validate_failure_batch!(batch, findings)
      error!("failure batch must be a JSON object") unless batch.is_a?(Hash)
      required = %w[batch_id candidate_sha failures]
      error!("failure batch fields are invalid") unless batch.keys.sort == required.sort
      error!("failure batch id is invalid") unless batch["batch_id"].is_a?(String) && batch["batch_id"].match?(EventLog::UUID)
      error!("failure batch candidate is invalid") unless batch["candidate_sha"].is_a?(String) && batch["candidate_sha"].match?(EventLog::GIT_SHA)
      groups = batch["failures"]
      error!("failure batch must not be empty") unless groups.is_a?(Array) && groups.any?
      failure_ids = []
      groups.each do |group|
        unless group.is_a?(Hash) && group.keys.sort == %w[failure_id occurrence_ids] &&
               group["failure_id"].is_a?(String) && group["failure_id"].match?(FailureLog::ID) &&
               group["occurrence_ids"].is_a?(Array) && group["occurrence_ids"].any? &&
               group["occurrence_ids"].uniq == group["occurrence_ids"]
          error!("failure batch group is invalid")
        end
        failure_ids << group["failure_id"]
        group["occurrence_ids"].each do |occurrence_id|
          finding = findings[occurrence_id]
          error!("failure batch references unknown occurrence #{occurrence_id}") unless finding
          error!("failure batch identity does not match occurrence") unless finding["failure_id"] == group["failure_id"]
          error!("failure batch mixes candidate SHAs") unless finding["candidate_sha"] == batch["candidate_sha"]
        end
      end
      error!("failure batch contains duplicate identities") unless failure_ids.uniq == failure_ids
    end

    def build_failure_batch(node, state)
      return nil unless node == writer_node
      return nil unless latest_done_by_node(state)[writer_node]

      pending = state.dig("failure_queue", "pending")
      candidate = current_candidate!(state)
      @failure_log.build_batch(pending: pending, candidate_sha: candidate)
    end

    def build_lease(node, attempt_id, lease_id, worktree, state)
      rules = node_policy(node)
      if rules.fetch("mutation_guard") && worktree.to_s.empty?
        error!("#{node} requires --worktree for mutation detection")
      end
      fingerprint = worktree && git_fingerprint(worktree)
      {
        "coordinator_policy_version" => policy.fetch("coordinator_policy_version"),
        "run_id" => run_id,
        "session" => session,
        "node" => node,
        "attempt_id" => attempt_id,
        "lease_id" => lease_id,
        "authority" => node == writer_node ? "write" : "read",
        "worktree" => worktree && File.realpath(worktree),
        "fingerprint" => fingerprint,
        "inputs" => input_artifact_snapshot(node, state),
        "failure_batch" => build_failure_batch(node, state),
        "created_at" => Time.now.utc.iso8601(6)
      }
    end

    def validate_mutation!(node, lease, allow_mutation:)
      return nil unless lease["worktree"]

      current = git_fingerprint(lease.fetch("worktree"))
      if !allow_mutation && current != lease["fingerprint"]
        error!("#{node} changed HEAD, index, or worktree without BUILD authority; use fail to record a red edge")
      end
      if node == writer_node && !current.fetch("clean")
        error!("BUILD must commit or remove all worktree changes before completion")
      end
      current
    end

    def git_fingerprint(worktree)
      requested = File.realpath(worktree)
      top = File.realpath(git_capture(requested, "rev-parse", "--show-toplevel").strip)
      error!("worktree path resolves to #{top}, expected #{requested}") unless top == requested
      common = git_capture(requested, "rev-parse", "--git-common-dir").strip
      common = File.expand_path(common, requested)
      head = git_capture(requested, "rev-parse", "HEAD").strip
      index = git_capture(requested, "ls-files", "--stage", "-z")
      diff = git_capture(requested, "diff", "--binary", "HEAD", "--")
      untracked = git_capture(requested, "ls-files", "--others", "--exclude-standard", "-z").split("\0")
      digest = Digest::SHA256.new
      digest << index << "\0" << diff
      untracked.sort.each do |relative|
        full = File.expand_path(relative, requested)
        error!("untracked path escapes worktree: #{relative}") unless full.start_with?("#{requested}/")
        stat = File.lstat(full)
        content = stat.symlink? ? File.readlink(full) : File.binread(full)
        digest << "\0" << relative << "\0" << stat.ftype << "\0" << content
      end
      status = git_capture(requested, "status", "--porcelain=v1", "-z", "--untracked-files=all")
      {
        "worktree" => requested,
        "common_git_dir" => File.realpath(common),
        "head" => head,
        "content_sha256" => digest.hexdigest,
        "clean" => status.empty?
      }
    rescue Errno::ENOENT => e
      error!("worktree fingerprint failed: #{e.message}")
    end

    def git_capture(worktree, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", worktree, *arguments)
      error!("git #{arguments.join(' ')} failed: #{stderr.strip}") unless status.success?
      stdout
    end

    def write_manifest!(path, manifest)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      content = JSON.pretty_generate(manifest) + "\n"
      if File.exist?(path)
        error!("coordinator manifest conflict at #{path}") unless File.binread(path) == content
        return
      end
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
    end

    def cleanup_manifest(path, manifest)
      expected = JSON.pretty_generate(manifest) + "\n"
      File.unlink(path) if File.file?(path) && File.binread(path) == expected
    rescue SystemCallError
      nil
    end

    def read_lease!(attempt_id)
      path = manifest_path(attempt_id, "lease")
      error!("missing persisted coordinator lease for #{attempt_id}") unless File.file?(path)
      lease = JSON.parse(File.read(path))
      error!("coordinator lease identity mismatch") unless lease["run_id"] == run_id &&
        lease["session"] == session && lease["attempt_id"] == attempt_id
      lease
    rescue JSON::ParserError => e
      error!("corrupt coordinator lease: #{e.message}")
    end

    def completion_manifest(lease, state:, final_fingerprint:, recovery:, outcome_impact:, outcome_disposition:)
      {
        "coordinator_policy_version" => policy.fetch("coordinator_policy_version"),
        "run_id" => run_id,
        "session" => session,
        "node" => lease.fetch("node"),
        "attempt_id" => lease.fetch("attempt_id"),
        "lease_id" => lease.fetch("lease_id"),
        "state" => state,
        "initial_fingerprint" => lease["fingerprint"],
        "final_fingerprint" => final_fingerprint,
        "recovery" => recovery,
        "outcome_impact" => outcome_impact,
        "outcome_disposition" => outcome_disposition
      }
    end

    def completion_recovery(findings:, pr:, candidate_sha:, disposition:)
      recovery = {"command" => "complete", "findings" => findings}
      recovery["pr"] = pr.to_i if pr
      recovery["candidate_sha"] = candidate_sha if candidate_sha
      recovery["disposition"] = disposition if disposition
      recovery
    end

    def resume_projection(state, worktree:, offline:)
      validate_open_reader_worktrees!(state)
      runnable, blocked = runnable_nodes(state)
      {
        "run_id" => run_id,
        "session" => session,
        "terminal" => state.fetch("terminal"),
        "current_candidate" => current_candidate(state),
        "open_attempts" => state.fetch("attempts").values.select { |attempt| attempt["state"] == "open" },
        "runnable" => runnable,
        "blocked" => blocked,
        "live_wakes" => state.fetch("wakes").values.select { |wake| %w[registered armed].include?(wake["state"]) },
        "failure_queue" => state.fetch("failure_queue").slice("pending", "processing", "processed", "stops", "stopped"),
        "outcome_coverage" => state.fetch("outcome_coverage"),
        "recovery" => {
          "partial_results" => state.fetch("attempts").values.select do |attempt|
            attempt["state"] == "open" && state.dig("manifests", attempt["attempt_id"], "result")
          end.map do |attempt|
            result = state.dig("manifests", attempt.fetch("attempt_id"), "result")
            {
              "attempt_id" => attempt.fetch("attempt_id"),
              "node" => attempt.fetch("node"),
              "result_state" => result.fetch("state"),
              "retry" => result["recovery"]
            }
          end
        },
        "git" => resume_git_projection(state, worktree),
        "external" => resume_external_projection(state, offline: offline)
      }
    end

    def validate_open_reader_worktrees!(state)
      state.fetch("attempts").values.each do |attempt|
        next unless attempt["state"] == "open" && attempt["node"] != writer_node

        lease = state.dig("manifests", attempt["attempt_id"], "lease")
        next unless lease && lease["worktree"]

        current = git_fingerprint(lease.fetch("worktree"))
        unless current == lease.fetch("fingerprint")
          error!("open #{attempt['node']} worktree changed outside BUILD; resume refused")
        end
      end
    end

    def resume_git_projection(state, explicit_worktree)
      build_attempts = state.fetch("attempts").values.select { |attempt| attempt["node"] == writer_node }
      latest_build = build_attempts.max_by { |attempt| attempt.fetch("start_seq") }
      lease = latest_build && state.dig("manifests", latest_build["attempt_id"], "lease")
      path = explicit_worktree || (lease && lease["worktree"])
      if latest_build && latest_build["state"] == "open"
        return {"state" => "write_in_progress", "worktree" => nil} unless path

        return {"state" => "write_in_progress", "worktree" => git_fingerprint(path)}
      end

      candidate = current_candidate(state)
      return {"state" => "not_applicable", "worktree" => path} unless candidate
      return {"state" => "unavailable", "reason" => "no persisted or supplied worktree"} unless path

      fingerprint = git_fingerprint(path)
      error!("resume worktree contains uncommitted changes outside BUILD") unless fingerprint.fetch("clean")
      error!("resume worktree HEAD does not match current candidate") unless fingerprint.fetch("head") == candidate
      result = latest_build && state.dig("manifests", latest_build["attempt_id"], "result")
      expected_common = result && result.dig("final_fingerprint", "common_git_dir")
      if expected_common && fingerprint["common_git_dir"] != expected_common
        error!("resume worktree belongs to a different Git repository")
      end
      {"state" => "current", "worktree" => fingerprint}
    end

    def resume_external_projection(state, offline:)
      published = state.fetch("published")
      return {"mode" => offline ? "offline" : "live", "pr" => {"state" => "not_published"}} unless published
      return {"mode" => "offline", "pr" => {"state" => "not_refreshed", "number" => published["pr"]}} if offline

      expected, live = reconcile_pr_identity!(state)
      {
        "mode" => "live",
        "pr" => {
          "state" => "available",
          "number" => published["pr"],
          "id" => live.dig("pull_request", "id"),
          "repository_id" => live.dig("repository", "id"),
          "identity_matches" => pr_identity_errors(expected, live).empty?,
          "is_draft" => live.dig("pull_request", "is_draft"),
          "head_sha" => live.dig("pull_request", "head_sha"),
          "lifecycle" => live.dig("pull_request", "state")
        }
      }
    rescue ContractError => e
      {"mode" => "live", "pr" => {"state" => "unavailable", "number" => published["pr"], "error" => e.message}}
    end

    def verify_done_gates!(state, candidate)
      error!("DONE candidate is missing") unless candidate
      errors = input_errors("DONE", state)
      optional_done_nodes.each do |node, family|
        next unless state.fetch("attempts").values.any? { |attempt| attempt["node"] == node }

        artifacts = current_artifacts(state, family, candidate: "current")
        errors << "activated optional gate #{node} lacks current evidence" unless artifacts.one? && artifact_passes?(artifacts.first, state)
      end
      error!(errors.join("; ")) if errors.any?
      verify_live_pr!(state)
      verify_live_ci!(state, candidate)
      verify_live_feedback!(state, candidate)
    end

    def optional_done_nodes
      policy.fetch("optional_done_nodes").transform_values { |rules| rules.fetch("artifact_family") }
    end

    # The PR may be a draft or marked ready by a person; the run never changes that state.
    def verify_live_pr!(state)
      published = state.fetch("published")
      error!("DONE requires a published PR") unless published
      expected, live = reconcile_pr_identity!(state)
      errors = pr_identity_errors(expected, live)
      error!("live PR identity changed: #{errors.join(', ')}") if errors.any?
      pr_state = live.fetch("pull_request")
      error!("DONE requires the PR to remain open") unless pr_state["state"] == "open"
      candidate = current_candidate!(state)
      error!("live PR head does not match current candidate") unless pr_state["head_sha"] == candidate
    rescue ContractError => e
      error!("could not verify live PR state: #{e.message}") unless e.is_a?(CoordinatorError)
      raise
    end

    def reconcile_pr_identity!(state)
      manifests = current_artifacts(state, "publish_manifest", candidate: "current")
      error!("PR reconciliation requires one current publish manifest") unless manifests.one?
      artifact = manifests.first
      expected = read_structured_artifact!(artifact)
      @pr_ci_contract.validate_publish!(expected, artifact: artifact)
      live = @pr_ci_adapter.reconcile_pr(
        repo: expected.dig("repository", "name_with_owner"),
        pr_number: expected.dig("pull_request", "number")
      )
      [expected, live]
    end

    def pr_identity_errors(expected, live)
      comparisons = {
        "repository id" => [expected.dig("repository", "id"), live.dig("repository", "id")],
        "repository name" => [expected.dig("repository", "name_with_owner"), live.dig("repository", "name_with_owner")],
        "pull request id" => [expected.dig("pull_request", "id"), live.dig("pull_request", "id")],
        "pull request number" => [expected.dig("pull_request", "number"), live.dig("pull_request", "number")],
        "base ref" => [expected.dig("pull_request", "base_ref"), live.dig("pull_request", "base_ref")],
        "head ref" => [expected.dig("pull_request", "head_ref"), live.dig("pull_request", "head_ref")]
      }
      comparisons.each_with_object([]) do |(label, values), errors|
        errors << label unless values[0] == values[1]
      end
    end

    def verify_live_ci!(state, candidate)
      publish_artifact = current_artifacts(state, "publish_manifest", candidate: "current")
      ci_artifacts = current_artifacts(state, "ci_result", candidate: "current")
      error!("live CI reconciliation requires one publish and one CI artifact") unless publish_artifact.one? && ci_artifacts.one?
      publish = read_structured_artifact!(publish_artifact.first)
      expected = read_structured_artifact!(ci_artifacts.first)
      @pr_ci_contract.validate_ci!(expected, artifact: ci_artifacts.first, expected_pass: true)
      live = @pr_ci_adapter.reconcile_ci(
        repo: publish.dig("repository", "name_with_owner"),
        pr_number: publish.dig("pull_request", "number"),
        candidate_sha: candidate,
        wake_id: expected.fetch("wake_id")
      )
      error!("live CI is #{live['overall']}, not passed") unless live["overall"] == "passed"
      identity_fields = %w[repository_id pull_request_id pr_number candidate_sha]
      changed = identity_fields.select { |field| live[field] != expected[field] }
      unless live["authoritative_run_ids"] == expected["authoritative_run_ids"]
        changed << "authoritative_run_ids"
      end
      error!("live CI identity changed: #{changed.join(', ')}") if changed.any?
    rescue ContractError => e
      error!("could not verify live CI state: #{e.message}") unless e.is_a?(CoordinatorError)
      raise
    end

    def verify_live_feedback!(state, candidate)
      publish_artifacts = current_artifacts(state, "publish_manifest", candidate: "current")
      feedback_artifacts = current_artifacts(state, "bot_feedback", candidate: "current")
      unless publish_artifacts.one? && feedback_artifacts.one?
        error!("live feedback reconciliation requires one publish and one bot feedback artifact")
      end
      publish = read_structured_artifact!(publish_artifacts.first)
      expected = read_structured_artifact!(feedback_artifacts.first)
      @feedback_contract.validate!(expected, artifact: feedback_artifacts.first, expected_pass: true)
      live = @feedback_adapter.reconcile(
        repo: publish.dig("repository", "name_with_owner"),
        pr_number: publish.dig("pull_request", "number"),
        candidate_sha: candidate,
        wake_id: expected.fetch("wake_id"),
        baseline_at: expected.fetch("baseline_at"),
        previous: expected
      )
      error!("live automated feedback is #{live['overall']}, not clean") unless live["overall"] == "clean"
      identity_fields = %w[author_policy_version baseline_at repository_id pull_request_id pr_number candidate_sha wake_id]
      changed = identity_fields.select { |field| live[field] != expected[field] }
      error!("live feedback identity changed: #{changed.join(', ')}") if changed.any?
      open_threads = open_automated_threads(publish, live)
      if open_threads.any?
        named = open_threads.map { |thread| "#{thread['path'] || '(no path)'} (comment #{thread['comment_id']})" }
        error!("unresolved automated review thread(s): #{named.join(', ')}")
      end
    rescue ContractError => e
      error!("could not verify live automated feedback: #{e.message}") unless e.is_a?(CoordinatorError)
      raise
    end

    # Live automated threads that are neither resolved, outdated, nor a declined finding.
    def open_automated_threads(publish, live)
      decisions = live.fetch("ledger").to_h { |entry| [[entry.fetch("feedback_id"), entry.fetch("revision")], entry.fetch("decision")] }
      declined = live.fetch("feedback").filter_map do |item|
        item["remote_id"] if decisions[[item.fetch("feedback_id"), item.fetch("revision")]] == "declined"
      end
      threads = @feedback_adapter.review_threads(
        repo: publish.dig("repository", "name_with_owner"),
        pr_number: publish.dig("pull_request", "number")
      )
      threads.select do |thread|
        thread.dig("author", "classification") == "automated" && !thread["is_resolved"] &&
          !thread["is_outdated"] && !declined.include?(thread["comment_id"])
      end
    end

    def runnable_nodes(state)
      return [[], {}] if state.fetch("terminal")

      runnable = []
      blocked = {}
      policy.fetch("nodes").each_key do |node|
        next if skipped_for_run?(node, state)

        errors = start_errors(node, state)
        if errors.empty?
          runnable << node
        else
          blocked[node] = errors
        end
      end
      [runnable, blocked]
    end
  end
end
