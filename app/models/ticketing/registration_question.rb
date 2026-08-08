# frozen_string_literal: true

module Ticketing
  # One validated question in a form version. Configuration is deliberately a
  # constrained JSON schema, never executable rules, and becomes immutable with
  # its published version.
  class RegistrationQuestion < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_questions"
    self.inheritance_column = nil

    TYPES = %w[short_text long_text single_choice multiple_choice checkbox date].freeze
    CHOICE_TYPES = %w[single_choice multiple_choice].freeze
    RESPONSE_SCOPES = %w[registration admission_slot].freeze
    SENSITIVITIES = %w[standard dietary accessibility].freeze
    VALIDATION_RULE_KEYS = %w[
      min_length max_length min_items max_items allowed_option_keys min_date max_date
    ].freeze

    belongs_to :registration_form_version, class_name: "Ticketing::RegistrationFormVersion"

    has_many :answers,
             class_name: "Ticketing::RegistrationAnswer",
             dependent: :restrict_with_exception

    validates :key, presence: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
    validates :type, presence: true, inclusion: { in: TYPES }
    validates :response_scope, presence: true, inclusion: { in: RESPONSE_SCOPES }
    validates :sensitivity, presence: true, inclusion: { in: SENSITIVITIES }
    validates :label, presence: true
    validates :required, inclusion: { in: [ true, false ] }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    before_validation :set_defaults

    validate :safe_text
    validate :stable_options
    validate :allowlisted_validation_rules
    validate :version_is_editable
    before_destroy :prevent_destroy_if_version_immutable

    scope :ordered, -> { order(:position) }
    scope :required, -> { where(required: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id registration_form_version_id key type response_scope sensitivity label help_text required
        position options validation_rules created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration_form_version answers]
    end

    private

    def set_defaults
      self.required = false if required.nil?
      self.position = 0 if position.nil?
      self.options = [] if options.nil?
      self.validation_rules = {} if validation_rules.nil?
    end

    def safe_text
      { label: label, help_text: help_text }.compact.each do |attribute, value|
        errors.add(attribute, :invalid) if value.to_s.match?(/<[^>]*>/)
      end
    end

    def stable_options
      unless options.is_a?(Array)
        errors.add(:options, :invalid)
        return
      end

      if CHOICE_TYPES.include?(type)
        validate_choice_options
      elsif options != []
        errors.add(:options, :invalid)
      end
    end

    def validate_choice_options
      if options.empty?
        errors.add(:options, :blank)
        return
      end

      normalized = options.filter_map do |option|
        unless option.is_a?(Hash)
          errors.add(:options, :invalid)
          next
        end

        option = option.stringify_keys
        unless option.keys.sort == %w[key label]
          errors.add(:options, :invalid)
          next
        end

        key = option["key"].to_s
        label = option["label"].to_s
        unless key.match?(/\A[a-z][a-z0-9_]*\z/) && label.present? && !label.match?(/<[^>]*>/)
          errors.add(:options, :invalid)
          next
        end

        key
      end

      errors.add(:options, :invalid) unless normalized.uniq.length == normalized.length
    end

    def allowlisted_validation_rules
      # Only declarative, type-specific rules are accepted; arbitrary patterns
      # or executable expressions must never enter organizer-managed schemas.
      unless validation_rules.is_a?(Hash)
        errors.add(:validation_rules, :invalid)
        return
      end

      rules = validation_rules.stringify_keys
      unknown = rules.keys - VALIDATION_RULE_KEYS
      errors.add(:validation_rules, :invalid) if unknown.any?
      validate_integer_rules(rules)
      validate_rule_scope(rules)
      validate_option_key_rules(rules)
      validate_date_rules(rules)
    end

    def validate_integer_rules(rules)
      %w[min_length max_length min_items max_items].each do |key|
        next unless rules.key?(key)
        next if rules[key].is_a?(Integer) && rules[key] >= 0

        errors.add(:validation_rules, :invalid)
      end

      %w[min_length min_items].each do |minimum|
        maximum = minimum.sub("min", "max")
        next unless rules[minimum].is_a?(Integer) && rules[maximum].is_a?(Integer)
        next if rules[maximum] >= rules[minimum]

        errors.add(:validation_rules, :invalid)
      end
    end

    def validate_rule_scope(rules)
      if (rules.keys & %w[min_length max_length]).any? && !%w[short_text long_text].include?(type)
        errors.add(:validation_rules, :invalid)
      end
      if (rules.keys & %w[min_items max_items]).any? && type != "multiple_choice"
        errors.add(:validation_rules, :invalid)
      end
      if (rules.keys & %w[min_date max_date]).any? && type != "date"
        errors.add(:validation_rules, :invalid)
      end
    end

    def validate_option_key_rules(rules)
      return unless rules.key?("allowed_option_keys")
      unless CHOICE_TYPES.include?(type) && rules["allowed_option_keys"].is_a?(Array)
        errors.add(:validation_rules, :invalid)
        return
      end

      option_keys = options.filter_map { |option| option.stringify_keys["key"] if option.is_a?(Hash) }
      allowed_option_keys = rules["allowed_option_keys"]
      return if allowed_option_keys.uniq.length == allowed_option_keys.length && allowed_option_keys.all? do |key|
        key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]*\z/) && option_keys.include?(key)
      end

      errors.add(:validation_rules, :invalid)
    end

    def validate_date_rules(rules)
      dates = rules.values_at("min_date", "max_date").compact
      return if dates.empty?

      unless type == "date"
        errors.add(:validation_rules, :invalid)
        return
      end

      unless dates.all? { |value| value.is_a?(String) && Date.iso8601(value) }
        errors.add(:validation_rules, :invalid)
        return
      end

      return unless rules["min_date"].is_a?(String) && rules["max_date"].is_a?(String)
      return if Date.iso8601(rules["max_date"]) >= Date.iso8601(rules["min_date"])

      errors.add(:validation_rules, :invalid)
    rescue Date::Error
      errors.add(:validation_rules, :invalid)
    end

    def version_is_editable
      return if registration_form_version.blank? || !registration_form_version.immutable?

      errors.add(:base, :immutable)
    end

    def prevent_destroy_if_version_immutable
      return unless registration_form_version&.immutable?

      raise ActiveRecord::ReadOnlyRecord, "Questions in published or retired versions are immutable"
    end
  end
end
