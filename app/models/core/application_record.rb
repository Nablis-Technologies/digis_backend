module Core
  class ApplicationRecord < ::ApplicationRecord
    self.abstract_class = true
    # Core's namespace file can be loaded after individual models in lazy
    # environments, so keep the table prefix on the abstract record itself.
    # This ensures Core models always target their `core_*` tables.
    self.table_name_prefix = "core_"

    # SECURITY: Do not expose all columns to Ransack by default.
    # Models must explicitly declare ransackable_attributes and ransackable_associations
    # to enable searching/filtering on specific fields.
    # This prevents accidental exposure of sensitive fields like password_digest, tokens, etc.
  end
end
