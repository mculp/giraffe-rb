# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "errors"

module Giraffe
  module Tickets
    module_function

    # A file is also useful for private/offline ticket sources; the same fields reach the model.
    def load(identifier: nil, file: nil)
      ticket = if file
                 JSON.parse(File.read(file))
               else
                 raise Error, "a ticket identifier or --ticket-file is required" if identifier.to_s.empty?
                 key = ENV.fetch("LINEAR_API_KEY") { raise Error, "LINEAR_API_KEY is required" }
                 uri = URI("https://api.linear.app/graphql")
                 request = Net::HTTP::Post.new(uri)
                 request["Authorization"] = key
                 request["Content-Type"] = "application/json"
                 request.body = JSON.generate("query" => "query($id: String!) { issue(id: $id) { identifier title description url } }", "variables" => {"id" => identifier})
                 response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(request) }
                 raise Error, "Linear ticket fetch failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)
                 document = JSON.parse(response.body)
                 raise Error, "Linear refused the ticket query" if document["errors"]
                 issue = document.dig("data", "issue") || raise(Error, "Linear ticket not found")
                 {"id" => issue["identifier"], "title" => issue["title"], "description" => issue["description"].to_s, "url" => issue["url"]}
               end
      %w[id title description].each { |key| raise Error, "ticket #{key} must be text" unless ticket[key].is_a?(String) }
      raise Error, "ticket id and title cannot be empty" if ticket.values_at("id", "title").any?(&:empty?)
      raise Error, "ticket exceeds 128 KB" if JSON.generate(ticket).bytesize > 131_072
      ticket
    rescue JSON::ParserError => e
      raise Error, "invalid ticket JSON: #{e.message}"
    end
  end
end
