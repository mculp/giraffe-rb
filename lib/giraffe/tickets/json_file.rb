# frozen_string_literal: true

require "json"

module Giraffe
  module Tickets
    # A file is also useful for private/offline ticket sources; the same fields reach the model.
    class JsonFile
      def initialize(path) = @path = path

      def fetch = JSON.parse(File.read(@path))
    end
  end
end
