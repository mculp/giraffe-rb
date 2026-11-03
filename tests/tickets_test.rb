# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/giraffe/tickets"

# What Tickets.load answers whichever source the ticket comes from. The key is removed first, so even a mistaken
# route to Linear stops before it could send anything; the Linear path has its own tests.
class TicketsTest < Minitest::Test
  TICKET = {"id" => "DEMO-1", "title" => "Show the greeting", "description" => "Say fixed."}.freeze
  LIMIT = 131_072

  def setup
    @tmp = Dir.mktmpdir("giraffe-tickets-test-")
    @old_env = ENV.to_h
    ENV.delete("LINEAR_API_KEY")
  end

  def teardown
    ENV.replace(@old_env)
    FileUtils.remove_entry(@tmp)
  end

  def write(document) = File.join(@tmp, "ticket.json").tap { |path| File.write(path, document.is_a?(String) ? document : JSON.generate(document)) }
  def load_file(document) = Giraffe::Tickets.load(file: write(document))
  def refused(**source) = assert_raises(Giraffe::Error) { Giraffe::Tickets.load(**source) }.message
  def refused_file(document) = refused(file: write(document))
  def padded(size) = TICKET.merge("description" => "x" * (size - JSON.generate(TICKET.merge("description" => "")).bytesize))

  def test_a_file_ticket_comes_back_with_every_field_it_holds
    ticket = TICKET.merge("url" => "https://example.test/DEMO-1", "labels" => ["ui"])
    assert_equal ticket, load_file(ticket)
  end

  def test_a_file_wins_over_an_identifier
    assert_equal TICKET, Giraffe::Tickets.load(identifier: "OTHER-9", file: write(TICKET))
  end

  def test_neither_an_identifier_nor_a_file_is_refused_before_a_key_is_asked_for
    [{}, {identifier: nil}, {identifier: ""}].each do |source|
      assert_equal "a ticket identifier or --ticket-file is required", refused(**source)
    end
  end

  def test_an_identifier_alone_is_fetched_from_linear_which_needs_its_key
    assert_equal "LINEAR_API_KEY is required", refused(identifier: "DEMO-1")
  end

  def test_id_title_and_description_must_each_be_text
    %w[id title description].each do |key|
      assert_equal "ticket #{key} must be text", refused_file(TICKET.merge(key => 7))
      assert_equal "ticket #{key} must be text", refused_file(TICKET.reject { |name, _| name == key })
    end
  end

  def test_a_ticket_needs_an_id_and_a_title_but_not_a_description
    %w[id title].each { |key| assert_equal "ticket id and title cannot be empty", refused_file(TICKET.merge(key => "")) }
    assert_equal "", load_file(TICKET.merge("description" => ""))["description"]
  end

  def test_a_ticket_may_be_exactly_128_kb_and_no_more
    assert_equal LIMIT, JSON.generate(load_file(padded(LIMIT))).bytesize
    assert_equal "ticket exceeds 128 KB", refused_file(padded(LIMIT + 1))
  end

  # Written as an escape, so the file is ASCII whatever the locale: each letter it decodes to is two bytes but one character.
  def test_the_size_counts_bytes_not_characters
    description = "\\u00e9" * (LIMIT / 2)
    assert_equal "ticket exceeds 128 KB", refused_file(%({"id":"DEMO-1","title":"T","description":"#{description}"}))
  end

  def test_a_file_that_is_not_json_is_reported_as_invalid_ticket_json
    assert_match(/\Ainvalid ticket JSON: /, refused_file("{ not json"))
  end

  def test_a_file_that_is_not_there_is_the_systems_own_error
    assert_raises(Errno::ENOENT) { Giraffe::Tickets.load(file: File.join(@tmp, "missing.json")) }
  end
end
