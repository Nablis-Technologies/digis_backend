# frozen_string_literal: true

module Ticketing
  module AccessCodes
    # Consumes an access code: validates it against the ticket type and deducts
    # `quantity` from its remaining uses. Returns the updated code on success.
    class Consume < Core::BaseService
      def initialize(ticket_type:, raw_code: nil, access_code: nil, quantity: 1, at: Time.current)
        @ticket_type = ticket_type
        @raw_code = raw_code
        @access_code = access_code
        @quantity = quantity.to_i
        @at = at.to_time.utc
      end

      def call
        return failure_i18n("ticketing.access_code.errors.quantity_invalid") unless @quantity.positive?
        return failure_i18n("ticketing.access_code.errors.invalid") unless valid_lookup_mode?

        event_id = @ticket_type.event_product.event_id
        result = nil
        ActiveRecord::Base.transaction do
          code = access_code_for(event_id)
          error_key = validation_error_key(code)
          result = if error_key
            failure_i18n("ticketing.access_code.errors.#{error_key}")
          else
            code.increment!(:used_count, @quantity)
            success(code)
          end
        end
        result
      rescue Core::Error => e
        failure(e)
      end

      private

      def access_code_for(event_id)
        scope = Ticketing::AccessCode.lock.where(ticket_type_id: @ticket_type.id)
        return scope.find_by(id: @access_code.id) if @access_code.present?

        scope.find_by(code_digest: Ticketing::AccessCode.code_digest_for(event_id:, code: @raw_code))
      end

      def valid_lookup_mode?
        raw_lookup = @raw_code.is_a?(String) && @raw_code.present?
        record_lookup = @access_code.present?
        return false if raw_lookup == record_lookup
        return raw_lookup unless record_lookup

        @access_code.is_a?(Ticketing::AccessCode) && @access_code.persisted?
      end

      def validation_error_key(code)
        return "invalid" if code.blank?
        return "inactive" unless code.active?
        return "not_yet_valid" if code.starts_at.present? && code.starts_at > @at
        return "expired" if code.expires_at.present? && code.expires_at <= @at
        return "exhausted" if code.max_uses.present? && code.used_count >= code.max_uses
        return "quantity_exceeds_per_use" if @quantity > code.max_quantity_per_use
        return "quantity_exceeds_remaining" if code.max_uses.present? && code.used_count + @quantity > code.max_uses

        nil
      end
    end
  end
end
