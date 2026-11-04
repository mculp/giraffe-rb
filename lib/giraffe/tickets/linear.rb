# frozen_string_literal: true

require "json"
require_relative "../errors"

module Giraffe
  module Tickets
    # One issue from Linear's GraphQL API, found by its identifier. `http` answers post(url, headers, body) with
    # something that has code, body and success?, and `env` holds the key.
    class Linear
      ENDPOINT = "https://api.linear.app/graphql"
      QUERY = "query($id: String!) { issue(id: $id) { identifier title description url } }"

      def initialize(identifier, http:, env:)
        @identifier, @http, @env = identifier, http, env
      end

      def fetch
        reply = @http.post(ENDPOINT, headers, body)
        raise Error, "Linear ticket fetch failed (HTTP #{reply.code})" unless reply.success?
        ticket_from(issue_in(JSON.parse(reply.body)))
      end

      private

      def headers = {"Authorization" => key, "Content-Type" => "application/json"}
      def key = @env.fetch("LINEAR_API_KEY") { raise Error, "LINEAR_API_KEY is required" }
      def body = JSON.generate("query" => QUERY, "variables" => {"id" => @identifier})

      def issue_in(document)
        raise Error, "Linear refused the ticket query" if document["errors"]
        document.dig("data", "issue") || raise(Error, "Linear ticket not found")
      end

      def ticket_from(issue) = {"id" => issue["identifier"], "title" => issue["title"], "description" => issue["description"].to_s, "url" => issue["url"]}
    end
  end
end
