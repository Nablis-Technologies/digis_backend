# frozen_string_literal: true

module Ticketing
  module AttendeeIndex
    # Writes the first scanner projection for an active credential. Index
    # versions are event-scoped and allocated under a transaction advisory lock
    # so concurrent package fulfillment cannot publish duplicate versions.
    class ProjectInitial < Core::BaseService
      def initialize(credential:, loaded_credential: nil, skip_existing_lookup: false, event: nil, index_lock_held: false)
        @credential = credential
        @loaded_credential = loaded_credential
        @skip_existing_lookup = skip_existing_lookup
        @event = event
        @index_lock_held = index_lock_held
      end

      def call
        outcome = nil
        ActiveRecord::Base.transaction do
          credential = load_credential
          existing = AttendeeIndexEntry.find_by(credential_id: credential.id) unless skip_existing_lookup
          outcome = success(existing) and next if existing
          outcome = failure_i18n("ticketing.package_issuance.errors.index_requires_active") and next unless credential.status == "active"

          outcome = Ticketing::AttendeeIndex::Upsert.call(
            credential:,
            loaded_credential: credential,
            event: @event,
            skip_existing_lookup: @event.present? && @index_lock_held,
            index_lock_held: @index_lock_held
          )
        end
        outcome
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.index_projection_failed"),
            code: "index_projection_failed",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :credential

      def skip_existing_lookup
        @skip_existing_lookup
      end

      def load_credential
        return @loaded_credential if @loaded_credential

        Ticketing::Credential.includes(
          :credential_generation,
          :holder_user,
          ticket: [ :owner_user, { event_product: [ :ticket_type, { product_accesses: :event_date } ] } ]
        ).find(credential.id)
      end
    end
  end
end
