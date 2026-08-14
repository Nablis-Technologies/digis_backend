# frozen_string_literal: true

require "test_helper"

module Commercial
  class ShadowComparisonJobTest < ActiveJob::TestCase
    test "delegates shadow comparison failures so the job can retry" do
      result = Core::BaseService::Result.success({ proposed_versions: [], comparisons: [] })
      called = nil

      original = Commercial::Shadow::Compare.method(:call)
      Commercial::Shadow::Compare.define_singleton_method(:call) do |**arguments|
        called = arguments
        result
      end
      assert_nothing_raised { Commercial::ShadowComparisonJob.perform_now }
    ensure
      Commercial::Shadow::Compare.define_singleton_method(:call, original) if original

      assert_equal [ :at ], called.keys
    end
  end
end
