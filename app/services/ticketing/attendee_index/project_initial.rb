# frozen_string_literal: true

require "digest"

module Ticketing
  module AttendeeIndex
    # Writes the first scanner projection for an active credential. Index
    # versions are event-scoped and allocated under a transaction advisory lock
    # so concurrent package fulfillment cannot publish duplicate versions.
    class ProjectInitial < Core::BaseService
      def initialize(credential:, loaded_credential: nil, issuance_context: nil, skip_existing_lookup: false)
        @credential = credential
        @loaded_credential = loaded_credential
        @issuance_context = issuance_context
        @skip_existing_lookup = skip_existing_lookup
      end

      def call
        outcome = nil
        ActiveRecord::Base.transaction do
          credential = load_credential
          existing = AttendeeIndexEntry.find_by(credential_id: credential.id) unless skip_existing_lookup
          outcome = success(existing) and next if existing
          outcome = failure_i18n("ticketing.package_issuance.errors.index_requires_active") and next unless credential.status == "active"

          Core::Database::AdvisoryLock.acquire!("ticketing-attendee-index", credential.event_id) unless issuance_context
          outcome = success(create_entry(credential))
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
      attr_reader :issuance_context

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

      def create_entry(loaded_credential)
        ticket = loaded_credential.ticket
        product = ticket.event_product
        ticket_type = product.ticket_type
        index_version = issuance_context&.fetch(:next_index_version) ||
          AttendeeIndexEntry.where(event_id: loaded_credential.event_id).maximum(:index_version).to_i + 1
        owner = ticket.owner_user
        holder = loaded_credential.holder_user || owner

        entry = AttendeeIndexEntry.create!(
          event: ticket.event,
          lookup_code: loaded_credential.lookup_code,
          phone_hash: phone_hash(holder),
          owner_phone_hash: phone_hash(owner),
          holder_name: holder_name(loaded_credential, ticket_type),
          credential: loaded_credential,
          ticket:,
          slot_positions: loaded_credential.slot_positions,
          credential_mode: loaded_credential.credential_generation.mode,
          generation_version: loaded_credential.credential_generation.version,
          entry_limit: loaded_credential.entry_limit,
          ticket_type: product.type,
          ticket_type_label: product.name,
          perks: [],
          product_access_ids: product.product_accesses.map(&:id),
          entry_validation_mode: ticket_type.entry_validation_mode,
          index_version:,
          removed: false
        )
        issuance_context[:next_index_version] += 1 if issuance_context
        entry
      end

      def holder_name(loaded_credential, ticket_type)
        return unless ticket_type.entry_validation_mode == "qr_and_id"

        loaded_credential.holder_name
      end

      def phone_hash(user)
        return if user&.phone.blank?

        Digest::SHA256.hexdigest(user.phone)
      end
    end
  end
end
