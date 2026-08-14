# frozen_string_literal: true

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

          event = Events::Event.lock.find(new_generation.ticket.event_id)
          Core::Database::AdvisoryLock.acquire!("ticketing-attendee-index", event.id)
          tombstone_old_entries(old_generation, event)
          unless project_active_credentials(new_generation, event)
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

      def tombstone_old_entries(generation, event)
        entries = Ticketing::AttendeeIndexEntry.where(
          credential_id: generation.credentials.select(:id), removed: false
        ).lock.to_a
        next_version = event.attendee_index_version.to_i

        entries.each do |entry|
          next_version += 1
          entry.update!(removed: true, index_version: next_version)
        end
        event.update!(attendee_index_version: next_version) if entries.present?
      end

      def project_active_credentials(generation, event)
        credentials = Ticketing::Credential.includes(
          :credential_generation,
          :holder_user,
          ticket: [ :owner_user, { event_product: [ :ticket_type, { product_accesses: :event_date } ] } ]
        ).where(credential_generation_id: generation.id, status: "active")

        credentials.find_each do |credential|
          projection = Ticketing::AttendeeIndex::ProjectInitial.call(
            credential:,
            loaded_credential: credential,
            skip_existing_lookup: true,
            event:,
            index_lock_held: true
          )
          next if projection.success?

          @projection_error = projection.error
          return false
        end
        true
      end
    end
  end
end
