# frozen_string_literal: true

module Ticketing
  module AccessCodes
    # Consumes an access code: validates it against the ticket type and deducts
    # `quantity` from its remaining uses. Returns the updated code on success.
    class Consume < Core::BaseService
      def initialize(ticket_type:, raw_code:, quantity: 1)
        @ticket_type = ticket_type
        @raw_code = raw_code
        @quantity = quantity.to_i
      end

      def call
        event_id = @ticket_type.event_product.event_id
        code = Ticketing::AccessCode.find_by(
          ticket_type_id: @ticket_type.id,
          code_digest: Ticketing::AccessCode.code_digest_for(event_id:, code: @raw_code)
        )
        return failure_i18n("ticketing.access_code.errors.invalid") if code.blank?
        return failure_i18n("ticketing.access_code.errors.inactive") unless code.active?
        return failure_i18n("ticketing.access_code.errors.not_yet_valid") if code.starts_at.present? && code.starts_at > Time.current
        return failure_i18n("ticketing.access_code.errors.expired") if code.expires_at.present? && code.expires_at <= Time.current
        return failure_i18n("ticketing.access_code.errors.exhausted") if code.max_uses.present? && code.used_count >= code.max_uses
        return failure_i18n("ticketing.access_code.errors.quantity_exceeds_per_use") if @quantity > code.max_quantity_per_use
        return failure_i18n("ticketing.access_code.errors.quantity_exceeds_remaining") if code.max_uses.present? && (code.used_count + @quantity) > code.max_uses

        ActiveRecord::Base.transaction do
          code.increment!(:used_count, @quantity)
        end

        success(code)
      rescue Core::Error => e
        failure(e)
      end
    end
  end
end
