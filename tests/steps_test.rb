# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/giraffe/steps"

class StepsTest < Minitest::Test
  # Constants stand in for the files a step would come in, under names no node has.
  def with_steps(constants)
    constants.each { |name, value| Giraffe::Steps.const_set(name, value) }
    yield
  ensure
    constants.each_key { |name| Giraffe::Steps.send(:remove_const, name) if Giraffe::Steps.const_defined?(name, false) }
  end

  def test_a_node_is_done_by_the_step_class_named_for_it
    with_steps(Widget: Class.new, WidgetBox: Class.new) do
      assert_instance_of Giraffe::Steps::Widget, Giraffe::Steps.for("WIDGET")
      assert_instance_of Giraffe::Steps::WidgetBox, Giraffe::Steps.for("WIDGET-BOX")
      refute_includes Giraffe::Steps.mixins, Giraffe::Steps::Widget
    end
  end

  def test_a_node_nothing_is_named_for_has_no_step
    assert_nil Giraffe::Steps.for("NO-SUCH-NODE")
  end

  def test_a_module_is_a_mixin_and_never_the_step_of_its_name
    with_steps(Gadget: Module.new) do
      assert_nil Giraffe::Steps.for("GADGET")
      assert_includes Giraffe::Steps.mixins, Giraffe::Steps::Gadget
    end
  end
end
