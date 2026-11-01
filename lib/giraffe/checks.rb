# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "etc"
require_relative "command"

module Giraffe
  class Checks
    def initialize(config, command: Command.new)
      @config, @command = config, command
    end

    def run(cwd, commands = @config["checks"])
      commands.map do |argv|
        actual = @config["sandbox_checks"] ? sandbox(cwd, argv) : argv
        # Do not pass controller/model/GitHub/Linear/Temper credentials to target-repo code.
        env = ENV.to_h.select { |key, _| %w[PATH HOME TMPDIR LANG LC_ALL USER SHELL GEM_HOME GEM_PATH BUNDLE_PATH].include?(key) }
        env["CI"] = "1"
        result = @command.capture(actual, cwd: cwd, env: env, clean_env: true, timeout: @config["check_timeout"])
        {"command" => argv, "exit_code" => result["status"], "excerpt" => (result["stdout"] + result["stderr"]).byteslice(-12_000, 12_000) || (result["stdout"] + result["stderr"])}
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
