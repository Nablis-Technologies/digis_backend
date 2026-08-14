# frozen_string_literal: true

module Finance
  # Soft cash floor for one provider/currency pair. It is checked against the
  # provider's live balance immediately before dispatch; it is not a copied
  # balance counter and does not block buyer refunds.
  class ProviderReservePolicy < Finance::ApplicationRecord
    self.table_name = "finance_provider_reserve_policies"

    include Core::AuditableModel

    validates :provider, :currency, :target_minor, presence: true
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :target_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :provider, uniqueness: { scope: :currency }
    validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id provider currency target_minor lock_version created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end
  end
end
