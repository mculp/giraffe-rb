# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../scripts/pr_ci_contract"
require_relative "../../scripts/temper_cli"
require_relative "backends"
require_relative "errors"

module Giraffe
  class Config
    DEFAULTS = {
      "store" => "mirrored", "backend" => Backends::DEFAULT, "base" => "origin/main", "pr_base" => "main", "spec_command" => [], "checks" => [], "lint" => [], "screen_checks" => [], "check_timeout" => 600,
      "sandbox_checks" => true, "runner" => "claude", "claude_bin" => "claude", "model" => "sonnet", "models" => {},
      "max_turns" => 30, "call_budget_usd" => 3.0, "run_budget_usd" => 25.0, "call_timeout" => 900,
      "max_fix_rounds" => 3, "instructions" => [], "skills" => {}, "dry_run" => false
    }.freeze
    attr_reader :data

    def self.load(path, overrides: {})
      raw = path ? JSON.parse(File.read(path)) : {}
      root = path ? File.dirname(File.expand_path(path)) : Dir.pwd
      new(DEFAULTS.merge(raw).merge(overrides), relative_to: root)
    rescue JSON::ParserError => e
      raise Error, "invalid configuration JSON: #{e.message}"
    end

    def initialize(data, relative_to: Dir.pwd, resolved: false)
      @data = data.dup
      @resolved = resolved
      unless resolved
        %w[repo runs_dir].each do |key|
          @data[key] = File.expand_path(@data.fetch(key, key == "runs_dir" ? ".giraffe/runs" : "."), relative_to)
        end
        @data["script"] = File.expand_path(@data["script"], relative_to) if @data["script"]
        @data["profiles"] = load_profiles(relative_to)
      end
      validate!
    end

    def [](key) = data[key]

    private

    def validate!
      unknown = data.keys - DEFAULTS.keys - %w[repo runs_dir context github_repo script profiles]
      raise Error, "unknown configuration key(s): #{unknown.join(', ')}" if unknown.any?
      raise Error, "repo does not exist" unless File.directory?(data.fetch("repo"))
      raise Error, "context is required (Temper context ref)" if data["store"] == "mirrored" && !data["context"].to_s.match?(PrGraph::TemperCli::CONTEXT_REF)
      raise Error, "store must be local or mirrored" unless %w[local mirrored].include?(data["store"])
      # A run started before backend existed has none, and stays readable.
      raise Error, "backend must be #{Backends.names.join(' or ')}" unless Backends.names.include?(data.fetch("backend", Backends::DEFAULT))
      raise Error, "models must map role names to model names" unless data["models"].is_a?(Hash) && data["models"].all? { |key, value| key.is_a?(String) && value.is_a?(String) && !value.empty? }
      raise Error, "github_repo must be OWNER/NAME" unless data["github_repo"].to_s.match?(PrGraph::PrCiContract::REPOSITORY_NAME)
      raise Error, "base must be a Git ref" if data["base"].to_s.empty? || data["base"].start_with?("-") || data["base"].match?(/[\r\n]/)
      # A run started before screen_checks existed has none, and stays readable.
      %w[checks lint screen_checks].each do |key|
        commands = data.fetch(key, [])
        raise Error, "#{key} must be an array of command argument arrays" unless commands.is_a?(Array) && commands.all? { |argv| argv.is_a?(Array) && argv.any? && argv.all? { |v| v.is_a?(String) && !v.include?("\0") } }
      end
      validate_spec_command!(data["spec_command"]) unless @resolved
      raise Error, "pr_base must be a ref name" unless data["pr_base"].is_a?(String) && !data["pr_base"].empty? && !data["pr_base"].start_with?("-")
      raise Error, "at least one executable check is required" if data["checks"].empty?
      %w[check_timeout call_timeout call_budget_usd run_budget_usd].each do |key|
        raise Error, "#{key} must be positive" unless data[key].is_a?(Numeric) && data[key].positive? && data[key].finite?
      end
      %w[max_turns max_fix_rounds].each do |key|
        raise Error, "#{key} must be a positive integer" unless data[key].is_a?(Integer) && data[key].positive?
      end
      raise Error, "runner must be claude or scripted" unless %w[claude scripted].include?(data["runner"])
      %w[dry_run sandbox_checks].each { |key| raise Error, "#{key} must be boolean" unless [true, false].include?(data[key]) }
    end

    # Only when a run starts: one already under way keeps what it was started with, and stays readable.
    def validate_spec_command!(command)
      raise Error, "spec_command must be an argument array naming {spec}" unless command.is_a?(Array) && command.all?(String) && command.any? { |arg| arg.include?("{spec}") }
      raise Error, "spec_command must pass the line as --flag={line}, which a whole-file run can drop" if command.each_cons(2).any? { |flag, value| flag.start_with?("-") && value == "{line}" }
    end

    def load_profiles(root)
      inputs = {"instructions" => data.fetch("instructions", [])}.merge(data.fetch("skills", {}))
      inputs.transform_values do |paths|
        raise Error, "profile inputs must be file path arrays" unless paths.is_a?(Array)
        paths.map do |path|
          full = File.expand_path(path, root)
          text = File.read(full)
          raise Error, "profile input exceeds 64 KB: #{full}" if text.bytesize > 65_536
          {"path" => full, "sha256" => Digest::SHA256.hexdigest(text), "text" => text}
        end
      end
    end
  end
end
