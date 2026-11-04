# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require_relative "../errors"

module Giraffe
  # Ways to confine a check's own code. Only macOS's is written.
  module Sandbox
    # Wraps a command in macOS's sandbox-exec. Its profile is all that stands between a candidate's own code and the
    # rest of the machine: the network, the credentials in the home directory, the keychain, and every place it could
    # write to. So it is built again for every command, from the home directory, PATH and temporary directory as they
    # are then, and nothing about the machine is remembered between commands.
    class Seatbelt
      NOT_MACOS = "sandboxed checks currently require macOS; use an isolated test host and explicitly set sandbox_checks=false elsewhere"
      # Everything is allowed but what the rules after these take away, and a later rule beats an earlier one.
      PREAMBLE = ["(version 1)", "(allow default)"].freeze
      # How a process reaches the keychain, which no file rule covers.
      KEYCHAIN = %w[com.apple.SecurityServer com.apple.securityd.xpc com.apple.secd].freeze
      # What in the home directory holds a credential, or a shell history that may hold one.
      CREDENTIALS = %w[.ssh .aws .config/gh .claude .git-credentials .netrc .npmrc .docker .gnupg .zsh_history .bash_history .config/temper .local/share/temper].freeze
      # Git dies without these.
      GIT_CONFIGURATION = %w[.gitconfig .config/git].freeze

      # The command line that runs `argv` in `cwd` under the profile. The network is shut unless asked for.
      def wrap(argv, cwd:, network: false)
        raise Error, NOT_MACOS unless macos?
        ["sandbox-exec", "-p", profile(cwd, network), *argv]
      end

      private

      def macos? = RbConfig::CONFIG["host_os"].include?("darwin")

      # Paths are named as they really are: a rule about a link would not cover what it points at.
      def profile(cwd, network)
        checkout = File.realpath(cwd)
        # Lint and builds need to write in the checkout and the temporary directories, and tools write to the devices.
        writable = [checkout, File.realpath(Dir.tmpdir), "/private/tmp", "/dev"]
        home = File.realpath(Dir.home)
        # The credentials come after the network's rules, so they stay out of whatever those leave readable.
        [*PREAMBLE, *network_rules(network, home, checkout), *write_rules(writable), *credential_rules(home), *keychain_rules].join("\n")
      end

      def network_rules(network, home, checkout) = network ? home_with_the_network(home, checkout) : ["(deny network*)"]
      def write_rules(places) = ["(deny file-write*)", "(allow file-write* #{subpaths(places)})"]
      def credential_rules(home) = ["(deny file-read* #{subpaths(CREDENTIALS.map { |path| File.join(home, path) })})"]
      def keychain_rules = ["(deny mach-lookup #{KEYCHAIN.map { |name| "(global-name #{name.inspect})" }.join(' ')})"]

      # What it reads can leave, so nothing of the home directory but its checkout, git's configuration, which git dies
      # without, and the tools on its PATH with the libraries their links point at. Not all that sits beside them:
      # ~/.cargo/bin and ~/.fly/bin share a directory with those tools' tokens.
      def home_with_the_network(home, checkout)
        tools = tools_in(home)
        readable = [checkout, *GIT_CONFIGURATION.map { |path| File.join(home, path) }, *tools, *libraries_beside(tools)]
        ["(deny file-read* #{subpaths([home])})", "(allow file-read-metadata)", "(allow file-read* #{subpaths(readable)})"]
      end

      def tools_in(home) = path_directories.select { |dir| dir.start_with?("#{home}/") }
      def path_directories = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).select { |dir| File.directory?(dir) }.map { |dir| File.realpath(dir) }
      def libraries_beside(tools) = tools.flat_map { |dir| %w[lib libexec].map { |name| File.join(File.dirname(dir), name) } }

      def subpaths(paths) = paths.map { |path| "(subpath #{path.inspect})" }.join(" ")
    end
  end
end
