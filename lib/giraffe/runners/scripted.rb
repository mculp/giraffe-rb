# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../errors"

module Giraffe
  module Runners
    # Test runner. File writes are explicit fixture operations, never interpreted shell text.
    class Scripted
      attr_reader :calls
      def initialize(script, positions: {}, on_advance: ->(_) {})
        @script = script.is_a?(String) ? JSON.parse(File.read(script)) : script
        @calls = []
        @positions, @on_advance = positions.dup, on_advance
      end

      def call(**request)
        @calls << request
        role = request.fetch(:step)
        index = @positions.fetch(role, 0)
        entry = @script.fetch(role) { raise Error, "no scripted step #{role}" }[index]
        raise Error, "script exhausted for #{request[:step]}" unless entry
        @positions[role] = index + 1
        @on_advance.call(@positions.dup)
        entry = entry.call(request) if entry.respond_to?(:call)
        raise entry if entry.is_a?(Exception)
        entry = {"output" => entry} unless entry.key?("output")
        entry.fetch("writes", {}).each do |relative, content|
          raise Error, "fixture writes are allowed only for BUILD" unless request[:writable]
          root = File.realpath(request.fetch(:cwd))
          path = File.expand_path(relative, root)
          raise Error, "fixture write escapes its directory" unless path.start_with?("#{root}/") && !relative.split("/").include?(".git")
          FileUtils.mkdir_p(File.dirname(path))
          raise Error, "fixture write follows an escaping symlink" unless File.realpath(File.dirname(path)).start_with?("#{root}/") || File.realpath(File.dirname(path)) == root
          File.write(path, content)
        end
        {"output" => entry.fetch("output"), "usage" => {"cost_usd" => entry.fetch("cost_usd", 0.0), "turns" => 1}}
      end
    end
  end
end
