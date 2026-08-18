# frozen_string_literal: true

require "digest"
require "json"

module Commercial
  module Resolution
    # Immutable aggregate returned by Commercial::ResolveCharges. Its signature
    # covers the quoted context and every component snapshot, allowing Orders
    # and later provider projections to prove they use the same quote result.
    class ChargeResult
      ATTRIBUTES = %i[
        currency settlement_currency quoted_at definition_signature overall_signature
        buyer_fee_total organizer_fee_total subsidy_total component_results
      ].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(
        currency:, quoted_at:, component_results:, buyer_fee_total:, organizer_fee_total:, subsidy_total:,
        settlement_currency: nil, definition_signature: nil
      )
        @currency = deep_freeze(currency)
        @settlement_currency = deep_freeze(settlement_currency || currency)
        @quoted_at = quoted_at.to_time.utc.freeze
        @component_results = deep_freeze(component_results.to_a)
        @buyer_fee_total = buyer_fee_total
        @organizer_fee_total = organizer_fee_total
        @subsidy_total = subsidy_total
        @definition_signature = deep_freeze(definition_signature || build_definition_signature)
        @overall_signature = deep_freeze(Digest::SHA256.hexdigest(JSON.generate(signature_payload)))
        freeze
      end

      def signature = overall_signature

      def to_h
        {
          currency:,
          settlement_currency:,
          quoted_at: quoted_at.iso8601(6),
          definition_signature:,
          overall_signature:,
          buyer_fee_total:,
          organizer_fee_total:,
          subsidy_total:,
          component_results: component_results.map(&:to_h)
        }.then { |value| deep_freeze(value) }
      end

      def as_json(*)
        to_h
      end

      private

      def signature_payload
        {
          currency:,
          settlement_currency:,
          quoted_at: quoted_at.iso8601(6),
          definition_signature:,
          buyer_fee_total:,
          organizer_fee_total:,
          subsidy_total:,
          component_results: component_results.map(&:to_h)
        }
      end

      def build_definition_signature
        definitions = component_results.map do |component|
          [ component.schedule_id, component.version_id, component.definition_digest ]
        end.sort_by { |definition| definition.map(&:to_s) }
        Digest::SHA256.hexdigest(JSON.generate(definitions))
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
