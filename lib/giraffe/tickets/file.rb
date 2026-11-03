# frozen_string_literal: true

require "json"

module Giraffe
  module Tickets
    # A file is also useful for private/offline ticket sources; the same fields reach the model.
    class File
      def initialize(path) = @path = path

      # ::File, because inside Tickets a bare File is this class.
      def fetch = JSON.parse(::File.read(@path))
    end
  end
end
