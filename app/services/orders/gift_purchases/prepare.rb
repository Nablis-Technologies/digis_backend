# frozen_string_literal: true

module Orders
  module GiftPurchases
    # Validates delivery-only gift details and asks Ticketing to reserve the
    # recipient identity. The durable GiftPurchase is created with its order item.
    class Prepare < Core::BaseService
      Intent = Data.define(
        :registration, :recipient, :recipient_phone, :recipient_phone_digest,
        :recipient_email, :recipient_email_digest, :note, :expires_at
      )

      def initialize(ticket_type:, purchaser:, recipient_phone:, recipient_email: nil, note: nil,
        package_quantity:, selected_event_date_id: nil, idempotency_key:)
        @ticket_type = ticket_type
        @purchaser = purchaser
        @recipient_phone = normalize_phone(recipient_phone)
        @recipient_email = recipient_email.to_s.strip.downcase.presence
        @note = note.to_s.strip.presence
        @package_quantity = package_quantity
        @selected_event_date_id = selected_event_date_id.presence
        @idempotency_key = idempotency_key
      end

      def call
        return failure(error("recipient_phone_invalid")) if recipient_phone.blank?
        return failure(error("recipient_is_purchaser", code: "gift_recipient_same_as_purchaser")) if
          same_recipient_as_purchaser?
        return failure(error("recipient_email_invalid")) if recipient_email.present? && !valid_email?
        return failure(error("note_too_long", code: "gift_note_too_long")) if
          note.to_s.length > Orders::GiftPurchase::NOTE_MAX_LENGTH
        return failure(error("quantity_invalid", code: "gift_quantity_invalid")) unless package_quantity.to_i == 1

        expiry = expires_at
        return failure(error("event_date_unavailable")) unless expiry && expiry > Time.current

        registration = Ticketing::Registrations::PrepareGift.call(
          ticket_type:,
          purchaser:,
          recipient_phone:,
          package_quantity:,
          selected_event_date_id:,
          idempotency_key:
        )
        return registration if registration.failure?

        success(Intent.new(
          registration: registration.value,
          recipient: registration.value.user,
          recipient_phone:,
          recipient_phone_digest: Orders::GiftPurchase.recipient_phone_digest_for(phone: recipient_phone),
          recipient_email:,
          recipient_email_digest: Orders::GiftPurchase.recipient_email_digest_for(email: recipient_email),
          note:,
          expires_at: expiry
        ))
      rescue ArgumentError => exception
        failure(Core::BusinessError.new(exception.message, code: "invalid_gift_intent", status: :unprocessable_entity))
      end

      private

      attr_reader :ticket_type, :purchaser, :recipient_phone, :recipient_email, :note,
                  :package_quantity, :selected_event_date_id, :idempotency_key

      def normalize_phone(value)
        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(value)
        normalized.present? ? "+#{normalized}" : nil
      end

      def valid_email?
        recipient_email.match?(URI::MailTo::EMAIL_REGEXP)
      end

      def same_recipient_as_purchaser?
        purchaser_phone = Core::PhoneIdentity::ResolveOrCreate.normalize(purchaser.phone)
        recipient_phone_number = Core::PhoneIdentity::ResolveOrCreate.normalize(recipient_phone)
        purchaser_phone.present? && purchaser_phone == recipient_phone_number
      end

      def expires_at
        product = Catalog::EventProduct.includes(product_accesses: :event_date).find(ticket_type.event_product_id)
        dates = if ticket_type.date_selection == "choose_one"
          [ product.product_accesses.filter_map(&:event_date)
            .find { |date| date.id.to_s == selected_event_date_id.to_s } ].compact
        else
          product.product_accesses.filter_map(&:event_date)
        end
        eligible_dates = dates.select { |date| date.status == "scheduled" }
        eligible_dates.map(&:ends_at).max
      end

      def error(key, code: key)
        Core::BusinessError.new(
          I18n.t("orders.gift_purchases.errors.#{key}"),
          code:,
          status: :unprocessable_entity
        )
      end
    end
  end
end
