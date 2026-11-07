# frozen_string_literal: true

require "minitest/autorun"

class PackagingTest < Minitest::Test
  def test_installed_gem_declares_the_schema_validator_it_requires
    specification = Gem::Specification.load(File.expand_path("../giraffe-rb.gemspec", __dir__))
    dependency = specification.runtime_dependencies.find { |item| item.name == "json_schemer" }
    refute_nil dependency, "installing giraffe-rb must install its schema validator"
    assert dependency.requirement.satisfied_by?(Gem::Version.new("2.5.0"))
  end
end
