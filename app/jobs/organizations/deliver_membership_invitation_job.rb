# frozen_string_literal: true

module Organizations
  class DeliverMembershipInvitationJob < ApplicationJob
    queue_as :notifications
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(invitation_id, delivery_revision)
      invitation = MembershipInvitation.find_by(id: invitation_id)
      return unless deliverable?(invitation, delivery_revision)

      sender = Rails.application.config.x.membership_invitation_delivery_sender
      unless sender.respond_to?(:call)
        persist_unavailable(invitation_id, delivery_revision)
        return "unknown"
      end

      token = invitation.claim_token_ciphertext
      return unless token.present?

      response = begin
        sender.call(
          phone: invitation.contact_ciphertext,
          url: Links::BrandedUrl.membership_invitation(invitation, token:),
          idempotency_key: "membership-invitation-#{invitation.id}-r#{delivery_revision}"
        )
      rescue StandardError
        persist_delivery_result(invitation_id, delivery_revision, "unknown")
        raise delivery_error, cause: nil
      end
      status = normalize_status(response)
      persist_delivery_result(invitation_id, delivery_revision, status)
      raise delivery_error, cause: nil if status.in?(%w[failed unknown])

      status
    end

    private

    def deliverable?(invitation, revision)
      invitation&.pending? &&
        invitation.delivery_status.in?(%w[queued failed unknown]) &&
        invitation.delivery_revision == revision.to_i &&
        invitation.expires_at > Time.current &&
        invitation.claim_token_ciphertext.present?
    end

    def normalize_status(result)
      return result.success? ? "accepted" : "failed" if result.is_a?(Messaging::Providers::DeliveryResult)

      status = result.respond_to?(:to_sym) ? result.to_sym.to_s : "unknown"
      status.in?(MembershipInvitation::DELIVERY_STATUSES) ? status : "unknown"
    end

    def persist_delivery_result(invitation_id, revision, status)
      MembershipInvitation.transaction do
        invitation = MembershipInvitation.lock.find_by(id: invitation_id)
        next unless deliverable?(invitation, revision)

        attempt = invitation.delivery_attempts + 1
        invitation.update!(delivery_status: status, delivery_attempts: attempt, last_delivery_at: Time.current)
        invitation.record_audit!(
          "organizations.membership_invitation.delivery_result",
          audit_key: "organizations-membership-invitation-delivery-#{invitation.id}-r#{revision}-a#{attempt}",
          audited_changes: { delivery_status: status, delivery_attempts: attempt },
          metadata: { invitation_id: invitation.id, delivery_revision: revision, outcome: status }
        )
      end
    end

    def persist_unavailable(invitation_id, revision)
      MembershipInvitation.transaction do
        invitation = MembershipInvitation.lock.find_by(id: invitation_id)
        next unless deliverable?(invitation, revision)

        invitation.update!(delivery_status: "unknown")
        invitation.record_audit!(
          "organizations.membership_invitation.delivery_unavailable",
          audit_key: "organizations-membership-invitation-delivery-unavailable-#{invitation.id}-r#{revision}",
          audited_changes: { delivery_status: "unknown" },
          metadata: { invitation_id: invitation.id, delivery_revision: revision, outcome: "unavailable" }
        )
      end
    end

    def delivery_error
      Core::Error.new(I18n.t("organizations.membership_invitation.errors.delivery_failed"))
    end
  end
end
