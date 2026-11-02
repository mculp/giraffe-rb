# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require_relative "command"
require_relative "../../scripts/content_scan"

module Giraffe
  class Checks
    # The exit status of a check past its limits, after timeout(1): to its caller it simply failed.
    OVER_LIMIT = 124
    # How a process reaches the keychain, which no file rule covers.
    KEYCHAIN = %w[com.apple.SecurityServer com.apple.securityd.xpc com.apple.secd].freeze

    def initialize(config, command: Command.new)
      @config, @command = config, command
    end

    def run(cwd, commands = @config["checks"], network: false)
      env = ENV.slice(*Command::PROJECT_ENV).merge("CI" => "1")
      commands.map do |argv|
        status, output = capture(@config["sandbox_checks"] ? sandbox(cwd, argv, network) : argv, cwd, env)
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

    def sandbox(cwd, argv, network)
      raise Error, "sandboxed checks currently require macOS; use an isolated test host and explicitly set sandbox_checks=false elsewhere" unless RbConfig::CONFIG["host_os"].include?("darwin")
      writes = [File.realpath(cwd), File.realpath(Dir.tmpdir), "/private/tmp", "/dev"]
      home = File.realpath(Dir.home)
      credentials = %w[.ssh .aws .config/gh .claude .git-credentials .netrc .npmrc .docker .gnupg .zsh_history .bash_history .config/temper .local/share/temper].map { |path| File.join(home, path) }
      # A later rule beats an earlier one, so credentials stay out of whatever the network's rules leave readable.
      profile = ["(version 1)", "(allow default)", *(network ? home_with_the_network(home, cwd) : "(deny network*)"), "(deny file-write*)",
                 "(allow file-write* #{subpaths(writes)})", "(deny file-read* #{subpaths(credentials)})",
                 "(deny mach-lookup #{KEYCHAIN.map { |name| "(global-name #{name.inspect})" }.join(' ')})"].join("\n")
      ["sandbox-exec", "-p", profile, *argv]
    end

    # What it reads can leave, so nothing of the home directory but its checkout, git's configuration, which git dies
    # without, and the tools on its PATH with the libraries their links point at. Not all that sits beside them:
    # ~/.cargo/bin and ~/.fly/bin share a directory with those tools' tokens.
    def home_with_the_network(home, cwd)
      tools = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).select { |dir| File.directory?(dir) }.map { |dir| File.realpath(dir) }.select { |dir| dir.start_with?("#{home}/") }
      libraries = tools.flat_map { |dir| %w[lib libexec].map { |name| File.join(File.dirname(dir), name) } }
      readable = [File.realpath(cwd), File.join(home, ".gitconfig"), File.join(home, ".config/git"), *tools, *libraries]
      ["(deny file-read* #{subpaths([home])})", "(allow file-read-metadata)", "(allow file-read* #{subpaths(readable)})"]
    end

    def subpaths(paths) = paths.map { |path| "(subpath #{path.inspect})" }.join(" ")
  end
end
