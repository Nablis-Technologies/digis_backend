# frozen_string_literal: true

module Finance
  module PayoutAccounts
    # Keeps account-number deduplication deterministic without persisting a
    # reversible lookup value.
    class PayoutAccountDigest
      def self.call(organization:, account_number:)
        Core::KeyedDigest.digest(namespace: organization.id, value: account_number)
      end
    end
  end
end
