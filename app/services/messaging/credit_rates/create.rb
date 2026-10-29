# frozen_string_literal: true

module Messaging
  module CreditRates
    # Creates an immutable draft price definition. Inputs are canonicalized
    # before the request digest is stored, so an idempotent retry cannot create
    # a second rate or silently change the quoted request.
    class Create < Core::BaseService
      include CommandSupport

      PERMISSION = "messaging_credit_rate.create"

      def initialize(actor:, attributes:, idempotency_key:)
        @actor = actor
        @attributes = attributes.deep_symbolize_keys
        @raw_idempotency_key = idempotency_key
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?(PERMISSION)

        handle_errors do
          key_digest = idempotency_digest
          request = canonical_attributes
          existing = CreditRateVersion.find_by(idempotency_key_digest: key_digest)
          return replay(existing, request) if existing

          rate = CreditRateVersion.create!(
            request.merge(
              version: request[:version] || next_version(request),
              status: "draft", idempotency_key_digest: key_digest,
              request_digest: request_digest(request), created_by: @actor
            )
          )
          audit!(
            key: "messaging-credit-rate-create-#{key_digest}", action: "messaging.credit_rate.created",
            rate:, changes: { "status" => [ nil, "draft" ] }, metadata: { "channel" => rate.channel }
          )
          success(rate)
        end
      end

      private

      def canonical_attributes
        @attributes.slice(
          :organization_id, :channel, :version, :currency, :unit_price_minor,
          :provider_cost_minor, :country_code, :volume_tiers, :effective_from, :effective_until
        ).tap do |attrs|
          attrs[:channel] = attrs[:channel].to_s.strip.downcase
          attrs[:currency] = attrs[:currency].to_s.strip.upcase
          attrs[:country_code] = attrs[:country_code].to_s.strip.upcase.presence
          attrs[:volume_tiers] ||= []
        end
      end

      def next_version(attributes)
        CreditRateVersion.where(
          organization_id: attributes[:organization_id], channel: attributes[:channel],
          currency: attributes[:currency], country_code: attributes[:country_code]
        ).maximum(:version).to_i + 1
      end

      def replay(existing, request)
        return success(existing) if existing.request_digest == request_digest(request)

        failure(error(:credit_idempotency_conflict, status: :conflict))
      end
    end
  end
end
