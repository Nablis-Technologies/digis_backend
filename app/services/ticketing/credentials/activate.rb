# frozen_string_literal: true

module Ticketing
  module Credentials
    # Converts a pending credential into a usable bearer credential only after
    # its current requirements are complete. QR signing, PNR allocation, and
    # attendee-index projection happen in one transaction, so no partial
    # activation can become visible to a scanner.
    class Activate < Core::BaseService
      def initialize(credential:, loaded_credential: nil, issuance_context: nil, event: nil, index_lock_held: false)
        @credential = credential
        @loaded_credential = loaded_credential
        @issuance_context = issuance_context
        @event = event
        @index_lock_held = index_lock_held
      end

      def call
        outcome = nil
        ActiveRecord::Base.transaction do
          credential = load_credential
          invalid = validate_activation(credential)
          if invalid
            outcome = failure(invalid)
            raise ActiveRecord::Rollback
          end

          credential.update!(
            status: "active",
            qr_token: Ticketing::Qr::Signer.call(credential:),
            lookup_code: lookup_code(credential),
            issued_at: Time.current
          )
          projection = Ticketing::AttendeeIndex::ProjectInitial.call(
            credential:,
            loaded_credential: credential,
            skip_existing_lookup: @loaded_credential.present?,
            event: @event,
            index_lock_held: @index_lock_held
          )
          if projection.failure?
            outcome = failure(projection.error)
            raise ActiveRecord::Rollback
          end

          outcome = success(@loaded_credential ? credential : credential.reload)
        end
        outcome
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.credential_activation_failed"),
            code: "credential_activation_failed",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      rescue Core::Error => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.credential_activation_failed"),
            code: "credential_activation_failed",
            status: :unprocessable_entity,
            meta: { cause: error.class.name }
          )
        )
      end

      private

      attr_reader :credential
      attr_reader :issuance_context

      def load_credential
        return @loaded_credential if @loaded_credential

        Ticketing::Credential.includes(
          :credential_generation,
          ticket: [ :owner_user, { event_product: [ :ticket_type, { product_accesses: :event_date } ] } ]
        ).lock.find(credential.id)
      end

      def validate_activation(loaded_credential)
        return activation_error(:credential_not_pending, "credential_not_pending", :conflict) unless
          loaded_credential.status.in?(%w[pending_claim pending_requirements])
        return activation_error(:generation_not_active, "generation_not_active", :conflict) unless
          loaded_credential.credential_generation.status == "active"

        nil
      end

      def lookup_code(loaded_credential)
        code = Core::LookupCodeService.generate(
          loaded_credential.event_id,
          reserved_codes: issuance_context&.fetch(:reserved_lookup_codes)
        )
        issuance_context[:reserved_lookup_codes] << code if issuance_context
        code
      end

      def activation_error(key, code, status)
        Core::BusinessError.new(
          I18n.t("ticketing.package_issuance.errors.#{key}"), code:, status:
        )
      end
    end
  end
end
