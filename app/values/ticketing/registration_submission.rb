# frozen_string_literal: true

module Ticketing
  # Immutable client input for one registration attempt. The command enriches
  # it with server-owned identity, ticket, form-schema, and exact consent evidence.
  RegistrationSubmission = Data.define(
    :package_quantity, :selected_event_date_id, :answers, :consents
  ) do
    alias_method :initialize_members, :initialize

    def initialize(package_quantity:, selected_event_date_id:, answers:, consents: [])
      initialize_members(
        package_quantity:,
        selected_event_date_id:,
        answers:,
        consents:
      )
    end

    def self.normalize_entries(raw_entries, permitted_fields:)
      return [] if raw_entries.nil?
      return unless raw_entries.is_a?(Array)

      entries = raw_entries.map do |raw_entry|
        attributes = parameter_hash(raw_entry)
        attributes&.slice(*permitted_fields).symbolize_keys
      end
      return if entries.any?(&:nil?)

      deep_freeze(entries)
    rescue NoMethodError, TypeError
      nil
    end

    def self.parameter_hash(value)
      attributes = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
      attributes.stringify_keys if attributes.is_a?(Hash)
    end
    private_class_method :parameter_hash

    def self.deep_freeze(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), copy|
          copy[deep_freeze(key)] = deep_freeze(nested)
        end.freeze
      when Array
        value.map { |nested| deep_freeze(nested) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end
    private_class_method :deep_freeze
  end

  RegistrationSubmission.const_set(
    :ANSWER_FIELDS,
    %w[form_version_id question_key package_unit_number admission_position value].freeze
  )
  RegistrationSubmission.const_set(
    :CONSENT_FIELDS,
    %w[
      consent_document_version_id request_uuid acceptance_method content_sha256
      package_unit_number admission_position idempotency_key
    ].freeze
  )
end
