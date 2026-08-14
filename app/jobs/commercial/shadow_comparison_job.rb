# frozen_string_literal: true

module Commercial
  # Compares scheduled definitions against production-shaped checkout
  # contexts without mutating checkout state. A failed result is raised for
  # retry and operator visibility.
  class ShadowComparisonJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(at: Time.current)
      result = Commercial::Shadow::Compare.call(at:)
      raise result.error if result.failure?

      result.value
    end
  end
end
