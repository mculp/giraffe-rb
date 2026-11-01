# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require_relative "command"
require_relative "../../scripts/content_scan"

module Giraffe
  class Checks
    # The exit status of a check past its limits, after timeout(1): to its caller it simply failed.
    OVER_LIMIT = 124

    def initialize(config, command: Command.new)
      @config, @command = config, command
    end

    def run(cwd, commands = @config["checks"])
      env = ENV.slice(*Command::PROJECT_ENV).merge("CI" => "1")
      commands.map do |argv|
        status, output = capture(@config["sandbox_checks"] ? sandbox(cwd, argv) : argv, cwd, env)
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

    def sandbox(cwd, argv)
      raise Error, "sandboxed checks currently require macOS; use an isolated test host and explicitly set sandbox_checks=false elsewhere" unless RbConfig::CONFIG["host_os"].include?("darwin")
      writes = [File.realpath(cwd), File.realpath(Dir.tmpdir), "/private/tmp", "/dev"]
      home = Dir.home
      credentials = %w[.ssh .aws .config/gh .claude .git-credentials .netrc].map { |path| File.join(home, path) }
      profile = ["(version 1)", "(allow default)", "(deny network*)", "(deny file-write*)",
                 "(allow file-write* #{writes.map { |path| "(subpath #{path.inspect})" }.join(' ')})",
                 "(deny file-read* #{credentials.map { |path| "(subpath #{path.inspect})" }.join(' ')})"].join("\n")
      ["sandbox-exec", "-p", profile, *argv]
    end
  end
end
