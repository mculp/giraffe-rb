# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/giraffe/tickets/https"
require_relative "../lib/giraffe/tickets/linear"
require_relative "../lib/giraffe/tickets/validated"

# The Linear path with the network replaced, so what is asked and how each answer is read can be checked.
class TicketsLinearTest < Minitest::Test
  Reply = Giraffe::Tickets::Https::Reply
  ENDPOINT = "https://api.linear.app/graphql"
  KEY = "not-a-real-key"
  WITH_KEY = {"LINEAR_API_KEY" => KEY}.freeze
  ISSUE = {"identifier" => "ENG-7", "title" => "Fix the greeting", "description" => "Say fixed.",
           "url" => "https://linear.app/example/issue/ENG-7"}.freeze
  BODY = '{"query":"query($id: String!) { issue(id: $id) { identifier title description url } }","variables":{"id":"ENG-7"}}'

  # Answers what it was given, and remembers what it was asked to post.
  class FakeHttp
    attr_reader :posts

    def initialize(reply) = (@reply, @posts = reply, [])

    def post(url, headers, body)
      @posts << [url, headers, body]
      @reply
    end
  end

  def reply(document, code: "200") = Reply.new(code, document.is_a?(String) ? document : JSON.generate(document))
  def found(issue = ISSUE) = reply({"data" => {"issue" => issue}})
  def linear(canned, env: WITH_KEY) = Giraffe::Tickets::Linear.new("ENG-7", http: (@http = FakeHttp.new(canned)), env: env)
  def refused(canned, env: WITH_KEY) = assert_raises(Giraffe::Error) { linear(canned, env: env).fetch }.message
  def validated_refusal(canned) = assert_raises(Giraffe::Error) { Giraffe::Tickets::Validated.new(linear(canned)).fetch }.message

  def test_a_found_issue_becomes_a_ticket_of_id_title_description_and_url
    expected = {"id" => "ENG-7", "title" => "Fix the greeting", "description" => "Say fixed.", "url" => "https://linear.app/example/issue/ENG-7"}
    assert_equal expected, linear(found).fetch
  end

  def test_fields_a_ticket_does_not_use_are_left_behind
    assert_equal %w[id title description url], linear(found(ISSUE.merge("state" => "Todo"))).fetch.keys
  end

  def test_an_issue_without_a_description_gets_an_empty_one
    assert_equal "", linear(found(ISSUE.merge("description" => nil))).fetch["description"]
  end

  def test_it_asks_linear_once_for_that_issue_with_the_key_it_was_given
    linear(found).fetch
    assert_equal [[ENDPOINT, {"Authorization" => KEY, "Content-Type" => "application/json"}, BODY]], @http.posts
  end

  def test_an_http_error_names_its_status
    assert_equal "Linear ticket fetch failed (HTTP 401)", refused(reply({}, code: "401"))
    assert_equal "Linear ticket fetch failed (HTTP 503)", refused(reply("", code: "503"))
  end

  def test_graphql_errors_are_refused_even_beside_data
    assert_equal "Linear refused the ticket query", refused(reply({"errors" => [{"message" => "Argument Validation Error"}]}))
    assert_equal "Linear refused the ticket query", refused(reply({"errors" => [{"message" => "x"}], "data" => {"issue" => ISSUE}}))
  end

  def test_a_missing_issue_is_not_found
    [{"data" => {"issue" => nil}}, {"data" => nil}, {}].each { |document| assert_equal "Linear ticket not found", refused(reply(document)) }
  end

  def test_a_missing_key_is_refused_before_anything_is_posted
    assert_equal "LINEAR_API_KEY is required", refused(found, env: {})
    assert_empty @http.posts
  end

  def test_what_linear_answers_meets_the_rules_every_ticket_does
    assert_equal "ticket title must be text", validated_refusal(found(ISSUE.merge("title" => nil)))
  end

  def test_a_reply_that_is_not_json_is_reported_as_invalid_ticket_json
    assert_match(/\Ainvalid ticket JSON: /, validated_refusal(reply("<html>")))
  end
end

# The real collaborator, with Net::HTTP replaced: the connection and the request are what a fetch has always sent.
class TicketsHttpsTest < Minitest::Test
  Response = Struct.new(:code, :body)
  URL = "https://api.linear.app/graphql"
  HEADERS = {"Authorization" => "a-key", "Content-Type" => "application/json"}.freeze

  # Remembers how a connection was opened and what went over it.
  class FakeNet
    attr_reader :opened, :sent

    def initialize(response) = (@response, @sent = response, [])

    def start(host, port, **options)
      @opened = [host, port, options]
      yield self
    end

    def request(request)
      @sent << request
      @response
    end
  end

  def post(response = Response.new("200", "{}"))
    @net = FakeNet.new(response)
    Giraffe::Tickets::Https.new(net: @net).post(URL, HEADERS, '{"a":1}')
  end

  def test_it_connects_over_tls_with_the_limits_a_fetch_has_always_had
    post
    assert_equal ["api.linear.app", 443, {use_ssl: true, open_timeout: 15, read_timeout: 30}], @net.opened
  end

  def test_it_sends_one_post_with_the_headers_and_body_it_was_given
    post
    request, = @net.sent
    assert_equal 1, @net.sent.size
    assert_equal ["POST", "/graphql", "a-key", "application/json", '{"a":1}'], [request.method, request.path, request["Authorization"], request["Content-Type"], request.body]
  end

  def test_it_hands_back_the_code_and_body_it_got
    reply = post(Response.new("201", "created"))
    assert_equal ["201", "created"], [reply.code, reply.body]
  end

  def test_only_a_2xx_code_is_a_success
    %w[200 201 204 299].each { |code| assert Giraffe::Tickets::Https::Reply.new(code, "").success?, code }
    %w[100 301 401 404 500].each { |code| refute Giraffe::Tickets::Https::Reply.new(code, "").success?, code }
  end
end
