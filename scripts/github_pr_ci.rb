#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "uri"
require_relative "pr_ci_contract"

module PrGraph
  class CommandRunner
    class CommandError < ContractError; end

    def initialize(timeout_seconds: 30)
      @timeout_seconds = timeout_seconds
    end

    def capture(*command)
      stdin, stdout, stderr, waiter = Open3.popen3(*command, pgroup: true)
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      unless waiter.join(@timeout_seconds)
        terminate(waiter.pid)
        raise CommandError, "command timed out after #{@timeout_seconds}s: #{command.take(3).join(' ')}"
      end
      output = out_reader.value
      error = err_reader.value
      unless waiter.value.success?
        raise CommandError, "command failed: #{command.take(3).join(' ')}: #{error.strip}"
      end
      output
    ensure
      stdout&.close
      stderr&.close
    end

    private

    def terminate(pid)
      Process.kill("TERM", -pid)
      sleep 0.05
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
  end

  class GitHubPrCi
    class AdapterError < ContractError; end

    def initialize(runner: CommandRunner.new, clock: -> { Time.now.utc }, contract: PrCiContract.new)
      @runner = runner
      @clock = clock
      @contract = contract
    end

    def publish(repo:, worktree:, base:, head:, title:, body_file:, pr_number: nil)
      repository_name!(repo)
      identity!(base, "base ref")
      identity!(head, "head ref")
      identity!(title, "pull request title")
      error!("pull request body file is missing") unless File.file?(body_file.to_s)
      candidate = git(worktree, "rev-parse", "HEAD").strip
      error!("worktree HEAD is not a full Git SHA") unless candidate.match?(EventLog::GIT_SHA)
      repository = api("repos/#{repo}")

      if pr_number
        pull_request = api("repos/#{repo}/pulls/#{positive_integer!(pr_number, 'PR number')}")
        action = "adopted"
      else
        owner = repo.split("/", 2).first
        query = URI.encode_www_form_component("#{owner}:#{head}")
        matches = api_pages("repos/#{repo}/pulls?state=open&head=#{query}&per_page=100").flatten
        error!("ambiguous open pull requests for #{head}") if matches.length > 1
        if matches.one?
          pull_request = api("repos/#{repo}/pulls/#{matches.first.fetch('number')}")
          action = "adopted"
        else
          created = @runner.capture(
            "gh", "pr", "create", "--repo", repo, "--draft", "--base", base,
            "--head", head, "--title", title, "--body-file", File.expand_path(body_file)
          ).strip
          number = Integer(created[%r{/pull/(\d+)(?:\z|[?#])}, 1], exception: false)
          error!("could not identify the created pull request") unless number&.positive?
          pull_request = api("repos/#{repo}/pulls/#{number}")
          action = "created"
        end
      end

      manifest = publish_manifest(repository, pull_request, action)
      @contract.validate_publish!(manifest, candidate_sha: candidate)
      pr = manifest.fetch("pull_request")
      error!("pull request base does not match #{base}") unless pr["base_ref"] == base
      error!("pull request head does not match #{head}") unless pr["head_ref"] == head
      manifest
    rescue KeyError, JSON::ParserError => e
      error!("malformed GitHub response: #{e.message}")
    end

    def reconcile_pr(repo:, pr_number:)
      repository_name!(repo)
      number = positive_integer!(pr_number, "PR number")
      repository = api("repos/#{repo}")
      pull_request = api("repos/#{repo}/pulls/#{number}")
      publish_manifest(repository, pull_request, "reconciled")
    rescue KeyError, JSON::ParserError => e
      error!("malformed GitHub response: #{e.message}")
    end

    def reconcile_ci(repo:, pr_number:, candidate_sha:, wake_id:)
      repository_name!(repo)
      positive_integer!(pr_number, "PR number")
      error!("candidate SHA is invalid") unless candidate_sha.to_s.match?(EventLog::GIT_SHA)
      error!("wake identity is invalid") unless wake_id.to_s.match?(EventLog::UUID)

      repository = api("repos/#{repo}")
      pull_request = api("repos/#{repo}/pulls/#{pr_number}")
      error!("pull request head moved to #{pull_request.dig('head', 'sha')}") unless pull_request.dig("head", "sha") == candidate_sha
      error!("pull request is not open") unless pull_request["state"] == "open"

      check_pages = api_pages("repos/#{repo}/commits/#{candidate_sha}/check-runs?filter=all&per_page=100")
      status_pages = api_pages("repos/#{repo}/commits/#{candidate_sha}/statuses?per_page=100")
      raw_checks = check_pages.flat_map { |page| page.fetch("check_runs", []) }
      raw_statuses = status_pages.flatten
      checks = normalize_check_runs(raw_checks, candidate_sha) + normalize_statuses(raw_statuses, candidate_sha)
      checks = add_lineage(checks)
      authoritative = checks.group_by { |check| check["logical_id"] }.values.map do |runs|
        runs.max_by { |check| check["attempt"] }
      end
      overall = if authoritative.empty? || authoritative.any? { |check| check["state"] == "pending" }
                  "pending"
                elsif authoritative.any? { |check| %w[failed cancelled].include?(check["state"]) }
                  "failed"
                else
                  "passed"
                end
      manifest = {
        "schema_version" => 1,
        "observed_at" => observed_at,
        "repository_id" => repository.fetch("node_id"),
        "pull_request_id" => pull_request.fetch("node_id"),
        "pr_number" => pull_request.fetch("number"),
        "candidate_sha" => candidate_sha,
        "wake_id" => wake_id,
        "overall" => overall,
        "authoritative_run_ids" => authoritative.map { |check| check["run_id"] }.sort,
        "checks" => checks.sort_by { |check| [check["logical_id"], check["attempt"]] }
      }
      @contract.validate_ci!(manifest)
      manifest
    rescue KeyError, JSON::ParserError => e
      error!("malformed GitHub response: #{e.message}")
    end

    private

    def api(endpoint)
      JSON.parse(@runner.capture("gh", "api", "-H", "Accept: application/vnd.github+json", endpoint))
    end

    def api_pages(endpoint)
      value = JSON.parse(@runner.capture(
        "gh", "api", "--paginate", "--slurp", "-H", "Accept: application/vnd.github+json", endpoint
      ))
      error!("paginated GitHub response must be an array") unless value.is_a?(Array)
      value
    end

    def git(worktree, *arguments)
      error!("worktree is missing") unless File.directory?(worktree.to_s)
      @runner.capture("git", "-C", File.expand_path(worktree), *arguments)
    end

    def publish_manifest(repository, pull_request, action)
      {
        "schema_version" => 1,
        "action" => action,
        "observed_at" => observed_at,
        "repository" => {
          "id" => repository.fetch("node_id"),
          "name_with_owner" => repository.fetch("full_name")
        },
        "pull_request" => {
          "id" => pull_request.fetch("node_id"),
          "number" => pull_request.fetch("number"),
          "url" => pull_request.fetch("html_url"),
          "base_ref" => pull_request.dig("base", "ref") || error!("pull request base ref is missing"),
          "head_ref" => pull_request.dig("head", "ref") || error!("pull request head ref is missing"),
          "head_sha" => pull_request.dig("head", "sha") || error!("pull request head SHA is missing"),
          "is_draft" => pull_request.fetch("draft"),
          "state" => pull_request.fetch("state"),
          "updated_at" => pull_request.fetch("updated_at")
        }
      }
    end

    def normalize_check_runs(checks, candidate_sha)
      checks.map do |check|
        if check["head_sha"] && check["head_sha"] != candidate_sha
          error!("stale check run #{check['id']} belongs to #{check['head_sha']}")
        end
        app = check["app"] || {}
        provider_identity = app["node_id"] || app["id"]&.to_s || app["slug"] || "github"
        logical_id = "check:#{provider_identity}:#{check.fetch('name')}"
        state = check_state(check)
        normalized_check(
          provider: "github-check",
          provider_identity: provider_identity,
          logical_id: logical_id,
          run_id: "check-run:#{check.fetch('id')}",
          revision_source: check,
          candidate_sha: candidate_sha,
          state: state,
          started_at: check["started_at"],
          completed_at: check["completed_at"],
          details_url: check["details_url"]
        )
      end
    end

    def normalize_statuses(statuses, candidate_sha)
      statuses.map do |status|
        if status["sha"] && status["sha"] != candidate_sha
          error!("stale commit status #{status['id']} belongs to #{status['sha']}")
        end
        creator = status["creator"] || {}
        provider_identity = creator["node_id"] || creator["id"]&.to_s || creator["login"] || "github"
        # GitHub keys the combined status by context alone. The creator is whichever token posted
        # the row, so one provider can post its pending and its success under different users.
        normalized_check(
          provider: "github-status",
          provider_identity: provider_identity,
          logical_id: "status:#{status.fetch('context')}",
          run_id: "status:#{status.fetch('id')}",
          revision_source: status,
          candidate_sha: candidate_sha,
          state: status_state(status.fetch("state")),
          started_at: status["created_at"],
          completed_at: %w[success failure error].include?(status["state"]) ? status["updated_at"] : nil,
          details_url: status["target_url"]
        )
      end
    end

    def normalized_check(provider:, provider_identity:, logical_id:, run_id:, revision_source:,
                         candidate_sha:, state:, started_at:, completed_at:, details_url:)
      {
        "provider" => provider,
        "provider_identity" => provider_identity,
        "logical_id" => logical_id,
        "run_id" => run_id,
        "attempt" => 0,
        "revision" => Digest::SHA256.hexdigest(JSON.generate(revision_source.sort.to_h)),
        "head_sha" => candidate_sha,
        "state" => state,
        "terminal" => state != "pending",
        "supersedes_run_id" => nil,
        "started_at" => started_at,
        "completed_at" => completed_at,
        "details_url" => details_url
      }
    end

    def add_lineage(checks)
      checks.group_by { |check| check["logical_id"] }.flat_map do |_logical_id, runs|
        ordered = runs.sort_by do |check|
          [check["started_at"].to_s, check["completed_at"].to_s, check["run_id"]]
        end
        ordered.each_with_index.map do |check, index|
          check.merge(
            "attempt" => index + 1,
            "supersedes_run_id" => index.zero? ? nil : ordered[index - 1]["run_id"]
          )
        end
      end
    end

    def check_state(check)
      return "pending" unless check["status"] == "completed"

      case check["conclusion"]
      when "success", "neutral", "skipped" then "passed"
      when "cancelled", "stale" then "cancelled"
      else "failed"
      end
    end

    def status_state(state)
      case state
      when "success" then "passed"
      when "pending" then "pending"
      else "failed"
      end
    end

    def observed_at
      @clock.call.utc.iso8601(6)
    end

    def positive_integer!(value, label)
      number = Integer(value, exception: false)
      error!("#{label} is invalid") unless number&.positive?
      number
    end

    def repository_name!(value)
      error!("repository must be owner/name") unless value.to_s.match?(PrCiContract::REPOSITORY_NAME)
    end

    def identity!(value, label)
      error!("#{label} is missing") unless value.is_a?(String) && !value.empty? && !value.match?(/[\r\n]/)
    end

    def error!(message)
      raise AdapterError, message
    end
  end
end
