# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require_relative "command"

module Giraffe
  class Checks
    # Do not pass controller/model/GitHub/Linear/Temper credentials to target-repo code.
    ENV_ALLOWED = [*Command::BASE_ENV, "SHELL", "GEM_HOME", "GEM_PATH", "BUNDLE_PATH"].freeze

    def initialize(config, command: Command.new)
      @config, @command = config, command
    end

    def run(cwd, commands = @config["checks"])
      env = ENV.slice(*ENV_ALLOWED).merge("CI" => "1")
      commands.map do |argv|
        actual = @config["sandbox_checks"] ? sandbox(cwd, argv) : argv
        result = @command.capture(actual, cwd: cwd, env: env, clean_env: true, timeout: @config["check_timeout"])
        output = result["stdout"] + result["stderr"]
        # A byte offset can land inside a character, which the journals could not then encode as JSON.
        {"command" => argv, "exit_code" => result["status"], "excerpt" => (output.byteslice(-12_000, 12_000) || output).scrub}
      end
    end

    private

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
