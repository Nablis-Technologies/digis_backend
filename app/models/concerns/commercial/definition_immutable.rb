# frozen_string_literal: true

module Commercial
  module DefinitionImmutable
    extend ActiveSupport::Concern

    included do
      validate :definition_must_be_mutable
      before_destroy :prevent_definition_destroy
    end

    private

    def definition_must_be_mutable
      return unless definition_version&.definition_immutable?

      errors.add(:base, I18n.t("commercial.definitions.errors.immutable"))
    end

    def prevent_definition_destroy
      return unless definition_version&.definition_immutable?

      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.definitions.errors.immutable")
    end

    def definition_version
      return fee_schedule_version if respond_to?(:fee_schedule_version)

      fee_component&.fee_schedule_version if respond_to?(:fee_component)
    end
  end
end
