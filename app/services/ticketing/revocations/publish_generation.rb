# frozen_string_literal: true

module Ticketing
  module Revocations
    # Publishes the durable package and credential revocations for one retired
    # generation. The generation and its credential rows remain intact so
    # scanners can reject stale versions and audit history can resolve the
    # exact credential that was used before replacement.
    class PublishGeneration < Core::BaseService
      def initialize(ticket:, through_version:, reason:)
        @ticket = ticket
        @through_version = through_version
        @reason = reason.to_s.strip
      end

      def call
        outcome = nil
        Ticketing::Ticket.transaction do
          ticket = Ticketing::Ticket.includes(:event).lock.find(@ticket.id)
          generation = ticket.credential_generations.includes(:credentials).lock.find_by(
            version: @through_version
          )
          unless generation
            outcome = failure(revocation_error(:generation_not_found, "generation_not_found", :not_found))
            raise ActiveRecord::Rollback
          end
          if @reason.blank?
            outcome = failure(revocation_error(:revocation_reason_required, "revocation_reason_required", :unprocessable_entity))
            raise ActiveRecord::Rollback
          end

          version = next_revocation_version(ticket.event_id)
          revoked_at = Time.current
          revoke_credentials!(generation, revoked_at, version)
          generation.update!(status: "revoked", revoked_at:, revocation_reason: @reason)
          package_revocation = publish_package_revocation!(ticket, version)
          outcome = success(package_revocation)
        end
        outcome
      rescue ActiveRecord::RecordInvalid => error
        failure(
          revocation_error(
            :generation_revocation_failed,
            "generation_revocation_failed",
            :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      rescue ActiveRecord::RecordNotUnique
        failure(revocation_error(:generation_conflict, "generation_conflict", :conflict))
      end

      private

      def revoke_credentials!(generation, revoked_at, version)
        credentials = generation.credentials.includes(
          :credential_generation, :admission_slot, :ticket, :event
        ).lock.to_a
        revocations = Ticketing::CredentialRevocation.where(
          credential_id: credentials.map(&:id)
        ).index_by(&:credential_id)

        credentials.each do |credential|
          revoke_credential!(credential, revoked_at, version, revocations[credential.id])
        end
      end

      def revoke_credential!(credential, revoked_at, version, existing_revocation)
        unless credential.status == "revoked"
          credential.update!(status: "revoked", revoked_at:, revocation_reason: @reason)
        end
        return if existing_revocation

        Ticketing::CredentialRevocation.create!(
          credential:,
          event: credential.event,
          reason: @reason,
          revoked_at:,
          revocation_version: version
        )
      end

      def publish_package_revocation!(ticket, version)
        revocation = Ticketing::Revocation.lock.find_or_initialize_by(ticket_id: ticket.id)
        revocation.assign_attributes(
          event: ticket.event,
          revoked_through_version: @through_version,
          revocation_version: version
        )
        revocation.save!
        revocation
      end

      def next_revocation_version(event_id)
        [
          Ticketing::Revocation.where(event_id:).maximum(:revocation_version).to_i,
          Ticketing::CredentialRevocation.where(event_id:).maximum(:revocation_version).to_i
        ].max + 1
      end

      def revocation_error(key, code, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.package_issuance.errors.#{key}"), code:, status:, errors:
        )
      end
    end
  end
end
