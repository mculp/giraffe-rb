# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/giraffe/schema"

# What the schema dialect lets through and what it says when it does not. A refusal's words are stored with the run and shown to
# the model that is asked again, and a refusal shows only the first few errors, so the order the errors come in is as much part of
# the answer as the verdict is. Nothing here reaches inside Giraffe::Schema: it is asked the way its callers ask it, through check!,
# validate! and errors, and for the keywords it knows.
class SchemaTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  Schema = Giraffe::Schema

  # What each role may answer with, at its smallest. Every role may also ask instead, with questions alone.
  OUTPUTS = {
    "triage" => {"questions" => [], "summary" => "A requested greeting change", "ui" => false, "bug" => false, "outcome_register" => {
      "why" => "People need the requested greeting.", "actors" => [{"id" => "actor:user", "situation" => "A person reading a greeting."}],
      "positive_postconditions" => [{"id" => "outcome:greeting", "statement" => "People see the requested greeting."}],
      "negative_face" => [{"id" => "constraint:input", "statement" => "Existing input remains readable."}], "declared_gaps" => []}},
    "investigate" => {"questions" => [], "summary" => "Greeting is in app.rb", "findings" => [{"ref" => "app.rb:1", "claim" => "Greeting is emitted here"}]},
    "plan" => {"questions" => [], "ui" => false,
               "implementation_plan" => {"steps" => [{"id" => "greeting", "classification" => "CONFORM", "intent" => "Change the greeting",
                                                      "outcome_ids" => %w[outcome:greeting], "evidence" => [
                                                        {"role" => "existing_pattern", "kind" => "codebase", "ref" => "app.rb:1", "claim" => "Greeting is emitted here"},
                                                        {"role" => "gap", "kind" => "gap", "reason" => "No prior art", "searched" => %w[app.rb]}]}]},
               "test_plan" => {"coverage" => [
                 {"outcome_id" => "outcome:greeting", "status" => "planned", "planned_node" => "VERIFY", "strategy" => "Execute the greeting check"},
                 {"outcome_id" => "constraint:input", "status" => "uncovered", "reason" => "Nothing runs it"}]}},
    "build" => {"questions" => [], "summary" => "Updated greeting"},
    "review" => {"questions" => [], "summary" => "One nit", "findings" => [{"id" => "f1", "severity" => "nit", "file" => "app.rb", "reason" => "Name the greeting"}]},
    "audit" => {"questions" => [],
                "clauses" => [{"clause_id" => "outcome:greeting", "verdict" => "met", "evidence" => [{"ref" => "app.rb:1", "note" => "Executed checks pass"}]},
                              {"clause_id" => "constraint:input", "verdict" => "unverifiable", "reason" => "No check reads input"}],
                "missed" => [{"criterion" => "Greets by name", "source" => "ticket", "verdict" => "unmet", "reason" => "Only the greeting changed"}],
                "screens" => [{"name" => "home", "verdict" => "fits", "note" => "The greeting fits the header"}]},
    "pr_body" => {"questions" => [], "title" => "Show requested greeting", "body" => "## Description\nChanges greeting."},
    "reproduce" => {"questions" => [], "steps" => ["Greet Ada"], "expected" => "Hello Ada", "observed" => "hello Ada", "code_path" => ["app.rb:1"],
                    "clause_ids" => %w[outcome:greeting], "expected_exit" => 1, "expected_output" => "wrong greeting",
                    "regression_spec" => "test/greeting_test.rb", "source" => 'abort "wrong greeting"'},
    "spec_audit" => {"questions" => [], "specs" => [{"ref" => "test/greeting_test.rb:1", "behavior" => "Keeps the name",
                                                      "classes" => %w[restates_literal mocks_subject], "patch" => "--- a/app.rb"}]}
  }.freeze

  def errors(schema, value) = Schema.errors(schema, value)
  def refusal(schema, value) = assert_raises(Giraffe::InvalidOutput) { Schema.validate!(schema, value) }.message
  def fault(schema) = assert_raises(Giraffe::InvalidOutput) { Schema.check!(schema) }.message
  def role_schema(role) = JSON.parse(File.read(File.join(ROOT, "schemas", "#{role}.json")))

  # The same schema with its keywords listed in every order. Errors come in an order of their own, not the order a schema lists its keywords in.
  def each_ordering(schema) = schema.to_a.permutation { |pairs| yield pairs.to_h }

  # --- type

  TYPES = {
    "object" => [[{}, {"a" => 1}], [[], "x", 1, 1.5, true, nil]],
    "array" => [[[], [1]], [{}, "x", 1, true, nil]],
    "string" => [["", "x"], [{}, [], 1, 1.5, true, nil]],
    "integer" => [[0, -3, 10**20], [1.0, 1.5, "1", true, {}, [], nil]],
    "boolean" => [[true, false], [0, 1, "true", "", {}, [], nil]]
  }.freeze

  def test_each_type_takes_what_ruby_calls_it_and_nothing_else
    TYPES.each do |type, (taken, refused)|
      taken.each { |value| assert_empty errors({"type" => type}, value), "#{type} should take #{value.inspect}" }
      refused.each { |value| assert_equal ["$ must be #{type}"], errors({"type" => type}, value), "#{type} should refuse #{value.inspect}" }
    end
  end

  def test_a_list_of_types_takes_a_value_of_any_of_them
    schema = {"type" => %w[string integer]}
    assert_empty errors(schema, "x")
    assert_empty errors(schema, 3)
    assert_equal ["$ must be string or integer"], errors(schema, 1.5)
    assert_equal ["$ must be string or integer"], errors(schema, nil)
    assert_empty errors({"type" => []}, 1), "no type asked for is no type refused"
  end

  def test_a_value_of_the_wrong_type_is_refused_for_that_alone
    wide = {"type" => "string", "minLength" => 5, "enum" => %w[abcdef], "const" => "abcdef", "oneOf" => [{"type" => "string"}]}
    each_ordering(wide) { |ordered| assert_equal ["$ must be string"], errors(ordered, 1), ordered.keys.inspect }
    object = {"type" => "object", "required" => %w[a], "properties" => {"a" => {"type" => "string"}}, "additionalProperties" => false}
    assert_equal ["$ must be object"], errors(object, [1])
    assert_equal ["$.a must be object"], errors({"properties" => {"a" => object}}, {"a" => "x"})
  end

  def test_a_type_outside_the_dialect_is_refused_only_when_it_is_asked_about
    number = {"type" => "number"}
    assert_same number, Schema.check!(number), "loading a schema does not look at its types"
    assert_equal "unsupported schema type: number", assert_raises(Giraffe::InvalidOutput) { errors(number, 1) }.message
    assert_equal "unsupported schema type: null", assert_raises(Giraffe::InvalidOutput) { errors({"type" => "null"}, nil) }.message
    assert_empty errors({"properties" => {"a" => number}}, {}), "no member is there to be asked"
    assert_raises(Giraffe::InvalidOutput) { errors({"properties" => {"a" => number}}, {"a" => 1}) }
  end

  def test_types_are_tried_in_the_order_given_and_the_first_to_take_the_value_ends_the_asking
    assert_empty errors({"type" => %w[string number]}, "x")
    assert_equal "unsupported schema type: number", assert_raises(Giraffe::InvalidOutput) { errors({"type" => %w[string number]}, 1) }.message
    assert_equal "unsupported schema type: number", assert_raises(Giraffe::InvalidOutput) { errors({"type" => %w[number string]}, "x") }.message
  end

  # --- const, enum and oneOf

  def test_const_must_be_equalled_and_names_what_it_wanted
    assert_empty errors({"const" => "met"}, "met")
    assert_equal ['$ must equal "met"'], errors({"const" => "met"}, "unmet")
    assert_equal ["$ must equal 1"], errors({"const" => 1}, 2)
    assert_equal ["$ must equal true"], errors({"const" => true}, "true")
    assert_equal ["$ must equal nil"], errors({"const" => nil}, "x"), "a const of nothing is still a const"
    assert_empty errors({"const" => nil}, nil)
    assert_equal ["$ must equal false"], errors({"const" => false}, nil)
    assert_equal ['$.verdict must equal "met"'], errors({"properties" => {"verdict" => {"const" => "met"}}}, {"verdict" => "no"})
  end

  def test_enum_lists_what_is_allowed
    verdict = {"type" => "string", "enum" => %w[unmet unverifiable]}
    assert_empty errors(verdict, "unmet")
    assert_equal ["$ is outside its enum"], errors(verdict, "met")
    assert_equal ["$ is outside its enum"], errors({"enum" => []}, "anything")
    assert_equal ["$.severity is outside its enum"], errors({"properties" => {"severity" => verdict}}, {"severity" => "met"})
  end

  def test_one_of_says_what_each_alternative_lacks
    answer = {"properties" => {"answer" => {"oneOf" => [{"type" => "string"}, {"type" => "integer"}]}}}
    assert_empty errors(answer, {"answer" => "x"})
    assert_equal ["$.answer must match exactly one of: $.answer must be string OR $.answer must be integer"], errors(answer, {"answer" => nil})
    shapes = {"oneOf" => [{"type" => "object", "required" => %w[a b]}, {"type" => "array"}]}
    assert_equal ["$ must match exactly one of: $.a is required, $.b is required OR $ must be array"], errors(shapes, {})
    assert_equal ["$ must match exactly one of: "], errors({"oneOf" => []}, 1), "no alternative can fit"
  end

  def test_one_of_refuses_a_value_that_fits_more_than_one_alternative
    assert_empty errors({"oneOf" => [{"type" => "string"}, {"type" => "object"}]}, {})
    assert_equal ["$ must match exactly one of: matched OR matched"], errors({"oneOf" => [{"type" => "object"}, {"required" => []}]}, {})
    assert_equal ["$ must match exactly one of: matched OR $.a is required OR matched"],
                 errors({"oneOf" => [{}, {"required" => %w[a]}, {"type" => "object"}]}, {})
  end

  def test_const_enum_and_one_of_come_in_that_order_whatever_order_the_schema_lists_them
    schema = {"const" => "b", "enum" => %w[a], "oneOf" => [{"const" => "c"}]}
    expected = ['$ must equal "b"', "$ is outside its enum", '$ must match exactly one of: $ must equal "c"']
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, "z"), ordered.keys.inspect }
  end

  # --- objects

  def test_required_names_each_missing_key_in_the_order_listed
    schema = {"required" => %w[b a c]}
    assert_equal ["$.b is required", "$.c is required"], errors(schema, {"a" => 1})
    assert_empty errors(schema, {"a" => nil, "b" => false, "c" => ""}), "a key that is there counts, however empty its value"
    assert_equal ["$.item.id is required"], errors({"properties" => {"item" => {"required" => %w[id]}}}, {"item" => {}})
  end

  def test_a_member_is_judged_by_the_property_that_describes_it
    schema = {"properties" => {"name" => {"type" => "string", "minLength" => 1}, "tags" => {"type" => "array", "items" => {"type" => "string"}}}}
    assert_empty errors(schema, {"name" => "x", "tags" => ["a"]})
    assert_equal ["$.name is too short", "$.tags[1] must be string"], errors(schema, {"name" => "", "tags" => ["a", 2]})
    assert_empty errors(schema, {"other" => 1}), "a member no property describes is allowed unless said otherwise"
  end

  def test_additional_properties_false_refuses_the_members_no_property_describes
    schema = {"properties" => {"name" => {"type" => "string"}}, "additionalProperties" => false}
    assert_empty errors(schema, {"name" => "x"})
    assert_equal ["$.extra is not allowed"], errors(schema, {"name" => "x", "extra" => 1})
    assert_equal ["$.a is not allowed", "$.b is not allowed"], errors({"additionalProperties" => false}, {"a" => 1, "b" => 2})
    assert_equal ["$.inner.extra is not allowed"], errors({"properties" => {"inner" => schema}}, {"inner" => {"extra" => 1}})
  end

  def test_additional_properties_other_than_false_allows_every_member
    [true, nil, {}, {"type" => "string"}, "no", 0].each do |allowed|
      assert_empty errors({"additionalProperties" => allowed}, {"a" => 1}), allowed.inspect
    end
  end

  def test_members_come_in_the_order_the_value_has_them
    schema = {"properties" => {"a" => {"type" => "string"}, "b" => {"type" => "string"}}, "additionalProperties" => false}
    expected = ["$.x is not allowed", "$.b must be string", "$.y is not allowed", "$.a must be string"]
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, {"x" => 1, "b" => 2, "y" => 3, "a" => 4}), ordered.keys.inspect }
  end

  def test_missing_keys_come_before_members_whatever_order_the_schema_lists_them
    schema = {"required" => %w[b c], "properties" => {"a" => {"type" => "string"}}, "additionalProperties" => false}
    expected = ["$.b is required", "$.c is required", "$.a must be string", "$.z is not allowed"]
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, {"a" => 1, "z" => 2}), ordered.keys.inspect }
  end

  # --- arrays, strings and numbers

  def test_an_array_is_held_to_its_size
    assert_equal ["$ has too few items"], errors({"minItems" => 1}, [])
    assert_empty errors({"minItems" => 1}, [0])
    assert_equal ["$ has too many items"], errors({"maxItems" => 2}, [1, 2, 3])
    assert_empty errors({"maxItems" => 2}, [1, 2])
    assert_equal ["$ has too many items"], errors({"maxItems" => 0}, [1]), "zero is a limit like any other"
    assert_empty errors({"maxItems" => 0}, [])
    assert_empty errors({"minItems" => 0}, [])
  end

  def test_items_are_judged_one_by_one_with_their_place
    schema = {"items" => {"type" => "string", "minLength" => 1}}
    assert_empty errors(schema, [])
    assert_equal ["$[1] is too short", "$[2] must be string", "$[3] is too short"], errors(schema, ["a", "", 5, ""])
    rows = {"properties" => {"rows" => {"items" => {"items" => {"type" => "integer"}}}}}
    assert_equal ["$.rows[1][0] must be integer"], errors(rows, {"rows" => [[1], ["x", 2]]})
  end

  def test_sizes_come_before_items_whatever_order_the_schema_lists_them
    schema = {"minItems" => 3, "maxItems" => 1, "items" => {"type" => "string"}}
    expected = ["$ has too few items", "$ has too many items", "$[0] must be string", "$[1] must be string"]
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, [1, 2]), ordered.keys.inspect }
  end

  def test_a_string_is_measured_in_characters
    assert_equal ["$ is too short"], errors({"minLength" => 1}, "")
    assert_empty errors({"minLength" => 1}, "x")
    assert_empty errors({"minLength" => 2}, "日本"), "two characters, six bytes"
    assert_equal ["$ is too short"], errors({"minLength" => 4}, "日本語"), "three characters, nine bytes"
    assert_equal ["$ is too short"], errors({"minLength" => 2}, "😀")
    assert_empty errors({"minLength" => 0}, "")
  end

  def test_a_number_is_held_to_its_limits_and_the_limits_are_included
    schema = {"type" => "integer", "minimum" => 1, "maximum" => 125}
    assert_empty errors(schema, 1)
    assert_empty errors(schema, 125)
    assert_equal ["$ is below minimum"], errors(schema, 0)
    assert_equal ["$ is above maximum"], errors(schema, 126)
    assert_equal ["$ must be integer"], errors(schema, 1.5), "the type is told alone, not the limits"
    assert_equal ["$ is below minimum"], errors({"minimum" => 0.5}, 0.25)
    assert_equal ["$ is above maximum"], errors({"maximum" => 0.5}, 0.75)
    assert_empty errors({"minimum" => 0.5, "maximum" => 0.5}, 0.5)
  end

  def test_limits_that_cannot_both_be_kept_are_both_told_the_minimum_first
    schema = {"minimum" => 5, "maximum" => 1}
    each_ordering(schema) { |ordered| assert_equal ["$ is below minimum", "$ is above maximum"], errors(ordered, 3), ordered.keys.inspect }
    assert_equal ["$ is above maximum"], errors(schema, 9)
    each_ordering(schema.merge("type" => "integer")) { |ordered| assert_equal ["$ must be integer"], errors(ordered, 3.5), ordered.keys.inspect }
  end

  def test_a_keyword_about_one_kind_of_value_says_nothing_of_another
    [
      [{"required" => %w[a], "properties" => {"a" => {"type" => "string"}}, "additionalProperties" => false}, ["x", 1, true, nil, [1]]],
      [{"minItems" => 2, "maxItems" => 0, "items" => {"type" => "string"}}, ["x", 1, true, nil, {"a" => 1}]],
      [{"minLength" => 5}, [[1], {"a" => 1}, 1, true, nil]],
      [{"minimum" => 5, "maximum" => 1}, ["x", [1], {"a" => 1}, true, nil]]
    ].each do |schema, others|
      others.each { |value| assert_empty errors(schema, value), "#{schema.keys} should say nothing of #{value.inspect}" }
    end
  end

  # --- the order of everything, and what a refusal shows of it

  def test_an_object_is_held_to_each_keyword_in_turn
    schema = {"type" => "object", "const" => {"c" => 1}, "enum" => [{"e" => 1}], "oneOf" => [{"required" => %w[o]}], "required" => %w[r],
              "properties" => {"a" => {"type" => "string"}}, "additionalProperties" => false}
    expected = ["$ must equal #{{"c" => 1}.inspect}", "$ is outside its enum", "$ must match exactly one of: $.o is required",
                "$.r is required", "$.a must be string", "$.z is not allowed"]
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, {"a" => 1, "z" => 2}), ordered.keys.inspect }
  end

  def test_an_array_is_held_to_each_keyword_in_turn
    schema = {"type" => "array", "const" => [3], "enum" => [[4]], "oneOf" => [{"minItems" => 5}], "minItems" => 3, "maxItems" => 1, "items" => {"type" => "string"}}
    expected = ["$ must equal [3]", "$ is outside its enum", "$ must match exactly one of: $ has too few items", "$ has too few items",
                "$ has too many items", "$[0] must be string", "$[1] must be string"]
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, [1, 2]), ordered.keys.inspect }
  end

  def test_a_string_is_held_to_each_keyword_in_turn
    schema = {"type" => "string", "const" => "abc", "enum" => %w[abc], "oneOf" => [{"minLength" => 5}], "minLength" => 3}
    expected = ['$ must equal "abc"', "$ is outside its enum", "$ must match exactly one of: $ is too short", "$ is too short"]
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, "ab"), ordered.keys.inspect }
  end

  def test_a_number_is_held_to_each_keyword_in_turn
    schema = {"type" => "integer", "const" => 4, "enum" => [5], "oneOf" => [{"minimum" => 10}], "minimum" => 4, "maximum" => 2}
    expected = ["$ must equal 4", "$ is outside its enum", "$ must match exactly one of: $ is below minimum", "$ is below minimum", "$ is above maximum"]
    each_ordering(schema) { |ordered| assert_equal expected, errors(ordered, 3), ordered.keys.inspect }
  end

  def test_validate_returns_the_value_it_was_given
    value = {"answer" => "ok"}
    assert_same value, Schema.validate!({"type" => "object", "required" => %w[answer]}, value)
  end

  def test_a_refusal_joins_the_errors_with_semicolons
    assert_equal "$ must be string", refusal({"type" => "string"}, 1)
    assert_equal "$.a is required; $.b is required", refusal({"required" => %w[a b]}, {})
    assert_equal "$.output must be string", assert_raises(Giraffe::InvalidOutput) { Schema.validate!({"type" => "string"}, 1, "$.output") }.message
    assert_equal ["$.output must be string"], Schema.errors({"type" => "string"}, 1, "$.output")
  end

  def test_a_refusal_is_an_invalid_output_which_is_an_error_of_the_harness
    assert_kind_of Giraffe::Error, assert_raises(Giraffe::InvalidOutput) { Schema.validate!({"type" => "string"}, 1) }
  end

  def test_a_refusal_shows_the_first_eight_errors_and_no_more
    schema = {"properties" => {"a" => {"type" => "string"}, "b" => {"type" => "string"}, "c" => {"type" => "string"}}, "required" => %w[r1 r2 r3 r4 r5 r6]}
    shown = (1..6).map { |index| "$.r#{index} is required" } + ["$.c must be string", "$.a must be string"]
    assert_equal shown.join("; "), refusal(schema, {"c" => 1, "a" => 2, "b" => 3})
    assert_equal 9, Schema.errors(schema, {"c" => 1, "a" => 2, "b" => 3}).length
  end

  # --- what the checked-in role schemas make of outputs

  def test_every_checked_in_schema_loads
    paths = Dir[File.join(ROOT, "schemas", "*.json")]
    refute_empty paths
    paths.each do |path|
      schema = JSON.parse(File.read(path))
      assert_same schema, Schema.check!(schema), path
    end
  end

  def test_each_role_takes_the_output_that_fits_it
    OUTPUTS.each { |role, output| assert_empty errors(role_schema(role), output), role }
  end

  def test_each_role_may_ask_instead_of_answer
    OUTPUTS.each_key { |role| assert_empty errors(role_schema(role), {"questions" => ["Which greeting?"]}), role }
  end

  def test_a_role_that_asks_and_answers_at_once_fits_neither_shape
    expected = "$ must match exactly one of: $.summary is not allowed OR $.questions has too many items"
    assert_equal [expected], errors(role_schema("build"), OUTPUTS.fetch("build").merge("questions" => ["Which greeting?"]))
  end

  def test_a_review_finding_without_its_reason_and_with_a_severity_outside_the_list
    findings = [{"id" => "f1", "severity" => "bad", "file" => "app.rb"}]
    expected = "$ must match exactly one of: $.questions has too few items, $.summary is not allowed, $.findings is not allowed " \
               "OR $.findings[0].reason is required, $.findings[0].severity is outside its enum"
    assert_equal [expected], errors(role_schema("review"), OUTPUTS.fetch("review").merge("findings" => findings))
  end

  def test_an_exit_code_beyond_its_limits_or_not_a_number
    schema = role_schema("reproduce")
    asking = "$ must match exactly one of: $.questions has too few items, $.steps is not allowed, $.expected is not allowed, " \
             "$.observed is not allowed, $.code_path is not allowed, $.clause_ids is not allowed, $.expected_exit is not allowed, " \
             "$.expected_output is not allowed"
    reproduce = OUTPUTS.fetch("reproduce")
    assert_equal ["#{asking} OR $.expected_exit is below minimum"], errors(schema, reproduce.merge("expected_exit" => 0)),
                 "an alternative's problems stop at the eighth"
    assert_equal ["#{asking} OR $.expected_exit is above maximum"], errors(schema, reproduce.merge("expected_exit" => 126))
    assert_equal ["#{asking} OR $.expected_exit must be integer"], errors(schema, reproduce.merge("expected_exit" => "1"))
  end

  def test_a_plan_step_with_a_classification_outside_the_list
    plan = OUTPUTS.fetch("plan")
    step = plan.dig("implementation_plan", "steps", 0).merge("classification" => "FIX")
    broken = plan.merge("implementation_plan" => {"steps" => [step]})
    expected = "$ must match exactly one of: $.questions has too few items, $.ui is not allowed, $.implementation_plan is not allowed, " \
               "$.test_plan is not allowed OR $.implementation_plan.steps[0].classification is outside its enum"
    assert_equal [expected], errors(role_schema("plan"), broken)
  end

  def test_a_plan_step_whose_evidence_fits_neither_shape
    plan = OUTPUTS.fetch("plan")
    step = plan.dig("implementation_plan", "steps", 0).merge("evidence" => [{"role" => "gap", "kind" => "codebase", "reason" => "None"}])
    broken = plan.merge("implementation_plan" => {"steps" => [step]})
    at = "$.implementation_plan.steps[0].evidence[0]"
    lacking = "#{at} must match exactly one of: #{at}.ref is required, #{at}.claim is required, #{at}.role is outside its enum, " \
              "#{at}.reason is not allowed OR #{at}.searched is required, #{at}.kind must equal \"gap\""
    assert_includes errors(role_schema("plan"), broken).first, lacking
  end

  def test_a_triage_flag_that_is_not_a_boolean
    expected = "$ must match exactly one of: $.questions has too few items, $.summary is not allowed, $.ui is not allowed, " \
               "$.bug is not allowed, $.outcome_register is not allowed OR $.ui must be boolean"
    assert_equal [expected], errors(role_schema("triage"), OUTPUTS.fetch("triage").merge("ui" => "no"))
  end

  def test_an_audit_clause_that_is_met_without_evidence
    audit = OUTPUTS.fetch("audit")
    clause = {"clause_id" => "outcome:greeting", "verdict" => "met"}
    message = errors(role_schema("audit"), audit.merge("clauses" => [clause])).first
    assert_includes message, "$.clauses[0] must match exactly one of: $.clauses[0].evidence is required " \
                             "OR $.clauses[0].reason is required, $.clauses[0].verdict is outside its enum"
  end

  def test_a_spec_class_outside_the_list_and_text_that_is_empty
    audit = OUTPUTS.fetch("spec_audit")
    spec = audit.dig("specs", 0)
    broken = audit.merge("specs" => [spec.merge("classes" => %w[restates_literal invented])])
    assert_includes errors(role_schema("spec_audit"), broken).first, "OR $.specs[0].classes[1] is outside its enum"
    empty = OUTPUTS.fetch("pr_body").merge("title" => "")
    assert_includes errors(role_schema("pr_body"), empty).first, "OR $.title is too short"
    gap = OUTPUTS.fetch("investigate").merge("findings" => [{"ref" => "app.rb:1"}])
    assert_includes errors(role_schema("investigate"), gap).first, "OR $.findings[0].claim is required"
  end

  def test_a_refusal_of_a_role_output_carries_the_message_the_model_is_shown
    broken = OUTPUTS.fetch("build").merge("summary" => "")
    assert_equal "$ must match exactly one of: $.questions has too few items, $.summary is not allowed OR $.summary is too short",
                 refusal(role_schema("build"), broken)
  end

  # --- loading a schema

  def test_the_dialect_has_these_keywords_and_no_others
    assert_equal %w[additionalProperties const enum items maxItems maximum minItems minLength minimum oneOf properties required type], Schema::KEYWORDS.sort
  end

  def test_check_returns_the_schema_it_was_given
    schema = {"type" => "object", "properties" => {"a" => {"type" => "array", "items" => {"type" => "string"}}}}
    assert_same schema, Schema.check!(schema)
  end

  def test_a_schema_that_is_not_an_object_is_refused
    [nil, [], "type", 1, true].each { |schema| assert_equal "schema must be an object", fault(schema), schema.inspect }
  end

  def test_every_keyword_of_the_dialect_loads
    schema = {"type" => "object", "properties" => {"a" => {"type" => "array", "items" => {"type" => "string", "minLength" => 1, "enum" => %w[x], "const" => "x"},
                                                           "minItems" => 0, "maxItems" => 3},
                                                   "b" => {"type" => "integer", "minimum" => 1, "maximum" => 2}},
              "required" => %w[a], "additionalProperties" => false, "oneOf" => [{"type" => "object"}]}
    assert_same schema, Schema.check!(schema)
  end

  def test_a_keyword_outside_the_dialect_is_named
    %w[$schema $ref $defs title description default examples format pattern maxLength multipleOf exclusiveMinimum exclusiveMaximum uniqueItems contains
       prefixItems minProperties maxProperties patternProperties propertyNames anyOf allOf not if then else dependentRequired].each do |keyword|
      assert_equal "unsupported schema keyword: #{keyword}", fault({"type" => "string", keyword => 1}), keyword
    end
  end

  def test_every_keyword_outside_the_dialect_is_named_in_the_order_the_schema_gives_them
    assert_equal "unsupported schema keyword: pattern, maxLength, format", fault({"pattern" => "x", "type" => "string", "maxLength" => 3, "format" => "date"})
  end

  def test_the_schemas_a_schema_holds_are_checked_too
    assert_equal "unsupported schema keyword: format", fault({"properties" => {"a" => {"format" => "date"}}})
    assert_equal "unsupported schema keyword: format", fault({"items" => {"format" => "date"}})
    assert_equal "unsupported schema keyword: format", fault({"oneOf" => [{"type" => "string"}, {"format" => "date"}]})
    assert_equal "unsupported schema keyword: pattern", fault({"properties" => {"a" => {"items" => {"oneOf" => [{"pattern" => "x"}]}}}})
    assert_equal "schema must be an object", fault({"properties" => {"a" => "string"}})
    assert_equal "schema must be an object", fault({"items" => []})
    assert_equal "schema must be an object", fault({"oneOf" => [{"type" => "string"}, 1]})
  end

  def test_the_first_fault_found_is_the_one_reported
    faults = {"properties" => {"p" => {"bogus_property" => 1}}, "items" => {"bogus_items" => 1}, "oneOf" => [{"bogus_alternative" => 1}]}
    each_ordering(faults.merge("bogus_own" => 1)) { |ordered| assert_equal "unsupported schema keyword: bogus_own", fault(ordered) }
    each_ordering(faults) { |ordered| assert_equal "unsupported schema keyword: bogus_property", fault(ordered) }
    each_ordering(faults.slice("items", "oneOf")) { |ordered| assert_equal "unsupported schema keyword: bogus_items", fault(ordered) }
    assert_equal "unsupported schema keyword: bogus_alternative", fault(faults.slice("oneOf"))
  end
end
