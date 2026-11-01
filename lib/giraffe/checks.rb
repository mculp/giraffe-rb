# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require_relative "command"

module Giraffe
  class Checks
    # Do not pass controller/model/GitHub/Linear/Temper credentials to target-repo code.
    ENV_ALLOWED = [*Command::BASE_ENV, "SHELL", "GEM_HOME", "GEM_PATH", "BUNDLE_PATH"].freeze
    # The exit status of a check past its limits, after timeout(1): to its caller it simply failed.
    OVER_LIMIT = 124

    def initialize(config, command: Command.new)
      @config, @command = config, command
    end

    def run(cwd, commands = @config["checks"])
      env = ENV.slice(*ENV_ALLOWED).merge("CI" => "1")
      commands.map do |argv|
        status, output = capture(@config["sandbox_checks"] ? sandbox(cwd, argv) : argv, cwd, env)
        # A byte offset can land inside a character, which the journals could not then encode as JSON.
        {"command" => argv, "exit_code" => status, "excerpt" => (output.byteslice(-12_000, 12_000) || output).scrub}
      end
    end

    private

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
