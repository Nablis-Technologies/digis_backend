# frozen_string_literal: true

require "set"

module Ticketing
  module AttendeeIndex
    # Applies a generation transition to the scanner projection. Old rows are
    # tombstoned before any new active credential is projected; lookup codes
    # and index versions therefore remain monotonic and never resurrect stale
    # credentials.
    class ApplyGeneration < Core::BaseService
      def initialize(old_generation:, new_generation:)
        @old_generation = old_generation
        @new_generation = new_generation
      end

      def call
        outcome = nil
        ActiveRecord::Base.transaction do
          old_generation = load_generation(@old_generation)
          new_generation = load_generation(@new_generation)
          unless new_generation.status == "active"
            outcome = failure_i18n(
              "ticketing.package_issuance.errors.index_generation_not_active"
            )
            raise ActiveRecord::Rollback
          end

          Core::Database::AdvisoryLock.acquire!("ticketing-attendee-index", new_generation.ticket.event_id)
          tombstone_old_entries(old_generation)
          unless project_active_credentials(new_generation)
            outcome = failure(@projection_error)
            raise ActiveRecord::Rollback
          end
          outcome = success(new_generation)
        end
        outcome
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.index_generation_failed"),
            code: "index_generation_failed",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      def load_generation(generation)
        Ticketing::CredentialGeneration.includes(:ticket, :credentials).lock.find(generation.id)
      end

      def tombstone_old_entries(generation)
        entries = Ticketing::AttendeeIndexEntry.where(
          credential_id: generation.credentials.select(:id), removed: false
        ).lock.to_a
        next_version = next_index_version(generation.ticket.event_id)

        entries.each do |entry|
          entry.update!(removed: true, index_version: next_version)
          next_version += 1
        end
      end

      def project_active_credentials(generation)
        context = {
          reserved_lookup_codes: reserved_lookup_codes(generation.ticket.event_id),
          next_index_version: next_index_version(generation.ticket.event_id)
        }
        credentials = Ticketing::Credential.includes(
          :credential_generation,
          :holder_user,
          ticket: [ :owner_user, { event_product: [ :ticket_type, { product_accesses: :event_date } ] } ]
        ).where(credential_generation_id: generation.id, status: "active")

        credentials.find_each do |credential|
          projection = Ticketing::AttendeeIndex::ProjectInitial.call(
            credential:,
            loaded_credential: credential,
            issuance_context: context
          )
          next if projection.success?

          @projection_error = projection.error
          return false
        end
        true
      end

      def reserved_lookup_codes(event_id)
        Ticketing::Credential.where(event_id:).where.not(lookup_code: nil).pluck(:lookup_code).to_set
      end

      def next_index_version(event_id)
        Ticketing::AttendeeIndexEntry.where(event_id:).maximum(:index_version).to_i + 1
      end
    end
  end
end
