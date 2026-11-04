# frozen_string_literal: true

require_relative "command"
require_relative "sandbox/seatbelt"
require_relative "../../scripts/content_scan"

module Giraffe
  class Checks
    # The exit status of a check past its limits, after timeout(1): to its caller it simply failed.
    OVER_LIMIT = 124

    def initialize(config, command: Command.new, sandbox: Sandbox::Seatbelt.new)
      @config, @command, @sandbox = config, command, sandbox
    end

    def run(cwd, commands = @config["checks"], network: false)
      env = ENV.slice(*Command::PROJECT_ENV).merge("CI" => "1")
      commands.map do |argv|
        status, output = capture(confined(argv, cwd, network), cwd, env)
        {"command" => argv, "exit_code" => status, "excerpt" => excerpt(output)}
      end
    end

    private

    # Project code can print anything, and this goes to state and into prompts. Redacted before cutting, so a
    # cut cannot leave part of a token behind.
    def excerpt(output)
      redacted = PrGraph::ContentScan.redact(output)
      # A byte offset can land inside a character, which the journals could not then encode as JSON.
      (redacted.byteslice(-12_000, 12_000) || redacted).scrub
    end

    def capture(argv, cwd, env)
      result = @command.capture(argv, cwd: cwd, env: env, clean_env: true, timeout: @config["check_timeout"])
      [result["status"], result["stdout"] + result["stderr"]]
    rescue CommandLimit => error
      [OVER_LIMIT, error.message]
    end

    # Unsandboxed only when the configuration says so, never because the host has no sandbox: it refuses instead.
    def confined(argv, cwd, network) = @config["sandbox_checks"] ? @sandbox.wrap(argv, cwd: cwd, network: network) : argv
  end
end
