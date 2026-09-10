# frozen_string_literal: true

module Core
  # Produces a deterministic, keyed digest for encrypted payout-account
  # deduplication without exposing the reversible account number.
  class PayoutAccountDigest
    def self.call(namespace:, account_number:)
      Core::KeyedDigest.digest(namespace:, value: account_number)
    end
  end
end
