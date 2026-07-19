# frozen_string_literal: true

require "test_helper"

class Core::BaseServiceTest < ActiveSupport::TestCase
  class SuccessfulCommand < Core::BaseService
    def call = success(value: 42)
  end

  class RejectedCommand < Core::BaseService
    def call
      failure Core::BusinessError.new("No", code: "rejected", status: :conflict)
    end
  end

  test ".call returns a successful result" do
    result = SuccessfulCommand.call

    assert result.success?
    assert_equal({ value: 42 }, result.value)
  end

  test "failure preserves the typed error" do
    result = RejectedCommand.call

    assert result.failure?
    assert_instance_of Core::BusinessError, result.error
    assert_equal "rejected", result.error.code
  end
end
