# frozen_string_literal: true

require "net/http"
require "uri"

module Giraffe
  module Tickets
    # The part of a fetch that touches the network, kept apart so the rest runs without one.
    class Https
      Reply = Data.define(:code, :body) do
        def success? = code.start_with?("2")
      end

      CONNECTION = {use_ssl: true, open_timeout: 15, read_timeout: 30}.freeze

      def initialize(net: Net::HTTP) = @net = net

      def post(url, headers, body)
        uri = URI(url)
        request = request_for(uri, headers, body)
        response = @net.start(uri.host, uri.port, **CONNECTION) { |http| http.request(request) }
        Reply.new(response.code, response.body)
      end

      private

      def request_for(uri, headers, body)
        Net::HTTP::Post.new(uri).tap do |request|
          headers.each { |name, value| request[name] = value }
          request.body = body
        end
      end
    end
  end
end
