# frozen_string_literal: true

module Ticketing
  # Delivers one scanner invitation from a durable ID/revision. Recipient phone
  # and capability are decrypted only for the injected sender call.
  class DeliverScannerInvitationJob < ApplicationJob
    queue_as :notifications
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(invitation_id, delivery_revision)
      invitation = Ticketing::ScannerInvitation.find_by(id: invitation_id)
      return unless deliverable?(invitation, delivery_revision)

      token = invitation.token
      return if token.blank?

      sender = Rails.application.config.x.scanner_invitation_delivery_sender
      result = begin
        if sender.respond_to?(:call)
          sender.call(
            phone: invitation.phone,
            url: Links::BrandedUrl.scanner_pairing(invitation, token:),
            idempotency_key: "scanner-invitation-#{invitation.id}-r#{delivery_revision}"
          )
        end
      rescue StandardError
        persist_delivery_result(invitation_id, delivery_revision, "failed")
        raise
      end

      status = normalize_status(result)
      return unless persist_delivery_result(invitation_id, delivery_revision, status)
      raise delivery_error if status == "failed"

      status
    end

    private

    def deliverable?(invitation, revision)
      invitation.present? &&
        invitation.status.in?(Ticketing::ScannerInvitation::PAIRABLE_STATUSES) &&
        !invitation.delivery_status.in?(%w[accepted delivered]) &&
        invitation.delivery_revision == revision.to_i &&
        invitation.expires_at > Time.current && invitation.token.present?
    end

    def normalize_status(result)
      if result.is_a?(Messaging::Providers::DeliveryResult)
        return result.success? ? "accepted" : "failed"
      end

      value = result.respond_to?(:to_sym) ? result.to_sym.to_s : "unknown"
      value.in?(Ticketing::ScannerInvitation::DELIVERY_STATUSES) ? value : "unknown"
    end

    def persist_delivery_result(invitation_id, revision, status)
      persisted = false
      Ticketing::ScannerInvitation.transaction do
        invitation = Ticketing::ScannerInvitation.lock.find_by(id: invitation_id)
        next unless deliverable?(invitation, revision)

        attempt = invitation.delivery_attempts + 1
        invitation.update!(
          delivery_status: status,
          delivery_attempts: attempt,
          last_delivery_at: Time.current
        )
        invitation.record_audit!(
          "ticketing.scanner_invitation.delivery_result",
          actor: nil,
          audit_key: "ticketing-scanner-invitation-delivery-result-#{invitation.id}-r#{revision}-a#{attempt}",
          audited_changes: { delivery_status: status, delivery_attempts: attempt },
          metadata: { delivery_revision: revision, outcome: status }
        )
        persisted = true
      end
      persisted
    end

    def delivery_error
      Core::Error.new(I18n.t("ticketing.scanner.errors.scanner_invitation_delivery_failed"))
    end
  end
end
