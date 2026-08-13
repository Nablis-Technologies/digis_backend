# frozen_string_literal: true

require "digest"

module Ticketing
  module AttendeeIndex
    # Atomically publishes one attendee-index row or tombstone. Event locking
    # allocates the authoritative index version; a removed credential cannot be
    # silently resurrected with its old PNR or QR identity.
    class Upsert < Core::BaseService
      def initialize(credential:, loaded_credential: nil, entry_attributes: nil, removed: false)
        @credential = credential
        @loaded_credential = loaded_credential
        @entry_attributes = entry_attributes&.symbolize_keys
        @removed = removed
      end

      def call
        outcome = nil
        Ticketing::ApplicationRecord.transaction do
          credential = load_credential
          event = Events::Event.lock.find(credential.event_id)
          Core::Database::AdvisoryLock.acquire!("ticketing-attendee-index", event.id)
          entry = Ticketing::AttendeeIndexEntry.lock.find_by(credential_id: credential.id)

          if @removed
            outcome = tombstone(entry, event)
            next
          end

          unless credential.status == "active"
            outcome = failure_i18n("ticketing.package_issuance.errors.index_requires_active")
            next
          end
          if entry&.removed?
            outcome = failure_i18n("ticketing.scanner_sync.errors.index_entry_removed")
            next
          end

          attributes = @entry_attributes || build_attributes(credential)
          outcome = publish_active(entry, event, attributes)
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

      def load_credential
        return @loaded_credential if @loaded_credential

        Ticketing::Credential.includes(
          :credential_generation,
          :holder_user,
          ticket: [ :event, :owner_user, { event_product: [ :ticket_type, { product_accesses: :event_date } ] } ]
        ).lock.find(credential.id)
      end

      def tombstone(entry, event)
        return success(nil) unless entry && !entry.removed?

        version = next_version(event)
        entry.update!(removed: true, index_version: version)
        event.update!(attendee_index_version: version)
        success(entry)
      end

      def publish_active(entry, event, attributes)
        if entry
          entry.assign_attributes(attributes)
          return success(entry) unless entry.changed?
        end

        version = next_version(event)
        attributes = attributes.merge(index_version: version, removed: false)
        published = entry || Ticketing::AttendeeIndexEntry.new
        published.assign_attributes(attributes.merge(event:, credential: credential, ticket: credential.ticket))
        published.save!
        event.update!(attendee_index_version: version)
        success(published)
      end

      def next_version(event)
        event.attendee_index_version.to_i + 1
      end

      def build_attributes(loaded_credential)
        ticket = loaded_credential.ticket
        product = ticket.event_product
        ticket_type = product.ticket_type
        owner = ticket.owner_user
        holder = loaded_credential.holder_user || owner
        {
          lookup_code: loaded_credential.lookup_code,
          phone_hash: phone_hash(holder),
          owner_phone_hash: phone_hash(owner),
          holder_name: ticket_type.entry_validation_mode == "qr_and_id" ? loaded_credential.holder_name : nil,
          slot_positions: loaded_credential.slot_positions,
          credential_mode: loaded_credential.credential_generation.mode,
          generation_version: loaded_credential.credential_generation.version,
          entry_limit: loaded_credential.entry_limit,
          ticket_type: product.type,
          ticket_type_label: product.name,
          perks: [],
          product_access_ids: product.product_accesses.map(&:id),
          entry_validation_mode: ticket_type.entry_validation_mode
        }
      end

      def phone_hash(user)
        return if user&.phone.blank?

        Digest::SHA256.hexdigest(user.phone)
      end
    end
  end
end
