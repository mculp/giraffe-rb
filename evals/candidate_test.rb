# frozen_string_literal: true

# Evaluator-owned acceptance tests run against an archived candidate commit.
require "csv"
require "minitest/autorun"
require File.join(Dir.pwd, "lib/acme/vendor_list")

# Preloaded to run a committed suite against a deliberately broken feature method, named
# "<method>:<mutant>". A suite that stays green under a mutant does not pin the behavior it names.
if ENV["PR_GRAPH_EVAL_MUTANT"]
  feature, mutant = ENV.fetch("PR_GRAPH_EVAL_MUTANT").split(":", 2)
  if Acme::VendorList.method_defined?(feature)
    Acme::VendorList.prepend(Module.new do
      define_method(feature) do |*args|
        case mutant
        when "returns-all" then instance_variable_get(instance_variables.find { |v| instance_variable_get(v).is_a?(Array) })
        when "returns-none" then super(*args) && []
        when "no-validation"
          begin
            super(*args)
          rescue ArgumentError
            []
          end
        when "returns-cents" then total_cents.to_s
        when "no-padding" then (total_cents / 100.0).to_s
        when "truncates" then format("%.2f", total_cents / 100)
        end
      end
    end)
    puts "PR_GRAPH_EVAL_MUTANT_APPLIED=#{feature}:#{mutant}"
  end
  return
end

# Preloaded only in bin/test's Ruby processes, not the evaluator's acceptance suite.
if ENV["PR_GRAPH_EVAL_FEATURE_PROBE"]
  module CommittedFeatureProbe
    def run
      feature = ENV.fetch("PR_GRAPH_EVAL_FEATURE_PROBE").to_sym
      exercised = false
      trace = TracePoint.new(:call) do |event|
        exercised = true if event.method_id == feature && event.self.is_a?(Acme::VendorList)
      end
      result = trace.enable { super }
      if exercised && result.passed? && result.assertions.positive?
        puts "PR_GRAPH_COMMITTED_FEATURE_TEST=#{feature}"
      end
      result
    end
  end

  Minitest::Test.prepend(CommittedFeatureProbe)
  return
end

scenario = ARGV.shift
abort "unknown scenario: #{scenario}" unless %w[new-ticket-no-ui adopt-existing-branch red-verify-routes-to-build spec-value-no-tautologies spec-value-no-mocks
                                                         temper-requirement-and-question].include?(scenario)

class CandidateTest < Minitest::Test
  def vendors
    [
      Acme::Vendor.new(name: 'Zed, "Lighting"', city: "Austin", total_cents: 12_050),
      Acme::Vendor.new(name: "Apex Grip", city: "Atlanta", total_cents: 4_999),
      Acme::Vendor.new(name: "Zero", city: "austin", total_cents: 0)
    ]
  end
end

if scenario == "spec-value-no-mocks"
  class CandidateTest
    def test_total_dollars_contract
      assert_equal "170.49", Acme::VendorList.new(vendors.first(2)).total_dollars
      assert_equal "120.50", Acme::VendorList.new(vendors.first(1)).total_dollars
      assert_equal "0.00", Acme::VendorList.new([]).total_dollars
    end
  end
elsif scenario == "spec-value-no-tautologies"
  class CandidateTest
    def listed
      %w[active paused closed active].each_with_index.map do |status, index|
        Acme::Vendor.new(name: "V#{index}", city: "Austin", total_cents: index, status: status)
      end
    end

    def test_status_defaults_to_active
      assert_equal "active", Acme::Vendor.new(name: "A", city: "Austin", total_cents: 1).status
    end

    def test_statuses_are_frozen_and_complete
      assert_equal %w[active paused closed], Acme::Vendor::STATUSES
      assert_predicate Acme::Vendor::STATUSES, :frozen?
    end

    def test_with_status_filters_exactly_and_keeps_order
      list = Acme::VendorList.new(listed)
      assert_equal [listed[0], listed[3]], list.with_status("active")
      assert_equal [listed[1]], list.with_status("paused")
      assert_equal [listed[2]], list.with_status("closed")
    end

    def test_with_status_rejects_unknown_statuses
      list = Acme::VendorList.new(listed)
      ["archived", "Active", "", nil].each do |status|
        assert_raises(ArgumentError) { list.with_status(status) }
      end
    end
  end
elsif scenario == "adopt-existing-branch"
  class CandidateTest
    def test_exact_city_filter
      list = Acme::VendorList.new(vendors)
      assert_equal [vendors[0]], list.in_city("Austin")
      assert_equal [vendors[2]], list.in_city("austin")
      assert_equal [], list.in_city("Missing")
      assert_equal vendors.sort_by(&:name), list.sorted_by_name
    end
  end
else
  class CandidateTest
    def test_csv_contract
      csv = Acme::VendorList.new(vendors).to_csv
      assert_kind_of String, csv
      assert_equal [
        %w[name city total],
        ["Apex Grip", "Atlanta", "49.99"],
        ['Zed, "Lighting"', "Austin", "120.50"],
        ["Zero", "austin", "0.00"]
      ], CSV.parse(csv)
    end

    def test_empty_csv_has_header
      assert_equal [%w[name city total]], CSV.parse(Acme::VendorList.new([]).to_csv)
    end
  end
end
