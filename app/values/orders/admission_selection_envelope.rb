# frozen_string_literal: true

module Orders
  # Immutable, allowlisted ticket-line input shared by admission commands.
  # Public payloads omit internal invitation aliases; nested form rows are
  # normalized by Ticketing's registration-submission boundary.
  class AdmissionSelectionEnvelope
    InvalidInput = Class.new(ArgumentError)
    INTERNAL_PROOF_FIELDS = %w[access_code invitation_token invitation].freeze
    PUBLIC_PROOF_FIELDS = %w[access_code invitation_token].freeze

    Item = Data.define(
      :event_product_id, :registration_id, :quantity, :selected_event_date_id,
      :answers, :consents, :audience_proof
    ) do
      def [](key)
        public_send(key)
      end

      def fetch(key)
        public_send(key)
      end
    end

    attr_reader :items

    def initialize(items:, public_payload: false)
      @items = normalize_items(items, public_payload:).freeze
      freeze
    end

    private

    def normalize_items(value, public_payload:)
      return value if typed_items?(value)
      return [] unless value.is_a?(Array)

      value.map { |item| normalize_item(item, public_payload:) }
        .sort_by(&:event_product_id)
    end

    def typed_items?(value)
      value.is_a?(Array) && value.all? { |item| item.is_a?(Item) }
    end

    def normalize_item(value, public_payload:)
      attributes = parameter_hash(value)
      raise InvalidInput unless attributes

      proof = parameter_hash(attributes["audience_proof"]) || {}
      Item.new(
        event_product_id: immutable(attributes["event_product_id"].to_s),
        registration_id: immutable(attributes["registration_id"].presence&.to_s),
        quantity: immutable(attributes["quantity"]),
        selected_event_date_id: immutable(attributes["selected_event_date_id"].presence&.to_s),
        answers: normalize_entries(attributes["answers"], Ticketing::RegistrationSubmission::ANSWER_FIELDS),
        consents: normalize_entries(attributes["consents"], Ticketing::RegistrationSubmission::CONSENT_FIELDS),
        audience_proof: immutable(proof.slice(*(public_payload ? PUBLIC_PROOF_FIELDS : INTERNAL_PROOF_FIELDS)).symbolize_keys)
      )
    end

    def normalize_entries(value, permitted_fields)
      Ticketing::RegistrationSubmission.normalize_entries(value, permitted_fields:)
    end

    def parameter_hash(value)
      attributes = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
      attributes.stringify_keys if attributes.is_a?(Hash)
    end

    def immutable(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), copy|
          copy[immutable(key)] = immutable(nested)
        end.freeze
      when Array
        value.map { |nested| immutable(nested) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end
  end
end
