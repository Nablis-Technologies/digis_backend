# frozen_string_literal: true

module Events
  class EventSetting < Events::ApplicationRecord
    self.table_name = "events_event_settings"

    AGE_RESTRICTION_KEYS = %w[has_restriction min_age max_age].freeze
    AGE_RESTRICTION_BOUND_KEYS = %w[min_age max_age].freeze
    AGE_BOUND_RANGE = 0..120

    # Shared by request assignment and the preview catalog projection so both
    # boundaries persist the same string-keyed, allowlisted JSONB shape.
    def self.normalize_age_restriction(value)
      return value unless value.is_a?(Hash)

      value.deep_stringify_keys.slice(*AGE_RESTRICTION_KEYS).tap do |normalized|
        AGE_RESTRICTION_BOUND_KEYS.each { |key| normalized.delete(key) if normalized[key].nil? }
      end
    end

    def self.age_restriction_errors(value)
      return [ [ "age_restriction", :object ] ] unless value.is_a?(Hash)

      restriction = normalize_age_restriction(value)
      has_restriction = restriction["has_restriction"]
      return [ [ "has_restriction", :boolean ] ] unless [ true, false ].include?(has_restriction)

      bounds = AGE_RESTRICTION_BOUND_KEYS.filter_map do |key|
        [ key, restriction[key] ] if restriction.key?(key) && !restriction[key].nil?
      end
      errors = []
      if has_restriction
        errors << [ "min_age", :bound_required ] if bounds.empty?
      else
        bounds.each { |key, _value| errors << [ key, :bound_not_allowed ] }
      end

      valid_bounds = bounds.each_with_object({}) do |(key, bound), valid|
        if bound.is_a?(Integer) && AGE_BOUND_RANGE.cover?(bound)
          valid[key] = bound
        else
          errors << [ key, :bound_range ]
        end
      end
      if valid_bounds.key?("min_age") && valid_bounds.key?("max_age") &&
         valid_bounds["min_age"] > valid_bounds["max_age"]
        errors << [ "max_age", :range_order ]
      end
      errors
    end

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_setting

    validates :event, presence: true
    validate :config_must_be_json_object
    validate :validate_age_restriction
    before_validation :normalize_age_restriction_config

    def age_restriction
      config.deep_stringify_keys["age_restriction"] if config.is_a?(Hash)
    end

    # Serializers use this projection so malformed legacy JSONB never escapes
    # and unknown keys are removed from the public contract.
    def safe_age_restriction
      value = age_restriction
      return unless self.class.age_restriction_errors(value).empty?

      self.class.normalize_age_restriction(value)
    end

    # Keep this event setting's unrelated JSONB keys while enforcing the small,
    # stable age-restriction contract at every write boundary.
    def age_restriction=(value)
      return unless config.is_a?(Hash)

      current_config = config.deep_stringify_keys
      self.config = current_config.merge("age_restriction" => self.class.normalize_age_restriction(value))
    end

    private

    def config_must_be_json_object
      return if config.is_a?(Hash)

      errors.add(:config, I18n.t("events.event_setting.errors.config_must_be_object"))
    end

    def normalize_age_restriction_config
      return unless config.is_a?(Hash)

      values = config.deep_stringify_keys
      return unless values.key?("age_restriction")

      self.config = values.merge(
        "age_restriction" => self.class.normalize_age_restriction(values["age_restriction"])
      )
    end

    def validate_age_restriction
      return unless config.is_a?(Hash)

      values = config.deep_stringify_keys
      return unless values.key?("age_restriction")

      self.class.age_restriction_errors(values["age_restriction"]).each do |field, message_key|
        add_age_restriction_error(field, message_key)
      end
    end

    def add_age_restriction_error(field, message_key)
      attribute = if field == "age_restriction"
        :"config.age_restriction"
      else
        :"config.age_restriction.#{field}"
      end

      errors.add(
        attribute,
        I18n.t("events.event_setting.errors.age_restriction.#{message_key}", field:)
      )
    end
  end
end
