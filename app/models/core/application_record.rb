module Core
  class ApplicationRecord < ::ApplicationRecord
    self.abstract_class = true

    # SECURITY: Do not expose all columns to Ransack by default.
    # Models must explicitly declare ransackable_attributes and ransackable_associations
    # to enable searching/filtering on specific fields.
    # This prevents accidental exposure of sensitive fields like password_digest, tokens, etc.
  end
end
