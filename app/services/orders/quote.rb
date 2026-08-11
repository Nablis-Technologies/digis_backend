# frozen_string_literal: true

module Orders
  # Immutable quote envelope for server-resolved Commercial evidence. Orders
  # carries the exact result forward; it never recalculates or mutates fees.
  Quote = Data.define(:commercial_results, :expires_at) do
    def initialize(commercial_results:, expires_at:)
      super(commercial_results: commercial_results.to_a.freeze, expires_at:)
      freeze
    end
  end
end
