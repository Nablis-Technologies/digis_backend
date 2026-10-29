# frozen_string_literal: true

module Orders
  # Immutable, allowlisted ticket-line input shared by admission commands.
  # Public payloads omit internal invitation aliases; nested form rows are
  # normalized by Ticketing's registration-submission boundary.
  class AdmissionSelectionEnvelope
    InvalidInput = Class.new(ArgumentError)
    INTERNAL_PROOF_FIELDS = %w[access_code invitation_token invitation].freeze
    PUBLIC_PROOF_FIELDS = %w[access_code invitation_token].freeze
    GIFT_FIELDS = %w[recipient_phone recipient_email note].freeze
    LINE_ID_FORMAT = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/.freeze

    Item = Data.define(
      :event_product_id, :registration_id, :quantity, :selected_event_date_id, :event_date_ids,
      :answers, :consents, :audience_proof, :gift, :line_id
    ) do
      def [](key)
        public_send(key)
      end

      def fetch(key)
        public_send(key)
      end

      def recipient_registration_data_present?
        registration_id.present? || answers.present? || consents.present? || audience_proof.present?
      end

      def line_key
        line_id.present? ? "client:#{line_id}" : "product:#{event_product_id}"
      end
    end

    attr_reader :items

    def initialize(items:, public_payload: false)
      @items = normalize_items(items, public_payload:).freeze
      validate_line_ids!
      freeze
    end

    def valid_repeated_gift_lines?
      items.group_by(&:event_product_id).values.all? do |product_items|
        product_items.one? || product_items.all? do |item|
          item.gift.present? && item.quantity == 1 && item.line_id.present?
        end
      end
    end

    private

    def normalize_items(value, public_payload:)
      return sort_items(value) if typed_items?(value)
      return [] unless value.is_a?(Array)

      sort_items(value.map { |item| normalize_item(item, public_payload:) })
    end

    def sort_items(value)
      value.sort_by { |item| [ item.event_product_id, item.line_id.to_s ] }
    end

    def typed_items?(value)
      value.is_a?(Array) && value.all? { |item| item.is_a?(Item) }
    end

    def normalize_item(value, public_payload:)
      attributes = parameter_hash(value)
      raise InvalidInput unless attributes

      proof = parameter_hash(attributes["audience_proof"]) || {}
      line_id = attributes["line_id"].to_s.strip.downcase.presence
      Item.new(
        event_product_id: immutable(attributes["event_product_id"].to_s),
        registration_id: immutable(attributes["registration_id"].presence&.to_s),
        quantity: immutable(attributes["quantity"]),
        selected_event_date_id: immutable(attributes["selected_event_date_id"].presence&.to_s),
        event_date_ids: immutable(Array(attributes["event_date_ids"]).compact.map(&:to_s).uniq.sort),
        answers: normalize_entries(attributes["answers"], Ticketing::RegistrationSubmission::ANSWER_FIELDS),
        consents: normalize_entries(attributes["consents"], Ticketing::RegistrationSubmission::CONSENT_FIELDS),
        audience_proof: immutable(proof.slice(*(public_payload ? PUBLIC_PROOF_FIELDS : INTERNAL_PROOF_FIELDS)).symbolize_keys),
        gift: normalize_gift(attributes["gift"]),
        line_id: immutable(line_id)
      )
    end

    def validate_line_ids!
      ids = items.filter_map(&:line_id)
      raise InvalidInput unless ids.all? { |id| LINE_ID_FORMAT.match?(id) } && ids.uniq.length == ids.length
    end

    def normalize_gift(value)
      return if value.nil?

      attributes = parameter_hash(value)
      raise InvalidInput unless attributes

      fields = attributes.slice(*GIFT_FIELDS)
      immutable(
        recipient_phone: fields["recipient_phone"].to_s.strip.presence,
        recipient_email: fields["recipient_email"].to_s.strip.downcase.presence,
        note: fields["note"].to_s.strip.presence
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
