# frozen_string_literal: true

module Ticketing
  module Transfers
    # Accepts a transfer after a recipient proves phone ownership with a
    # transfer-scoped OTP. A password is optional: passwordless recipients get
    # a signed ticket view and can upgrade their shadow account later.
    class AcceptGuest < Core::BaseService
      Result = Data.define(
        :transfer, :ticket, :ticket_view_url, :user, :access_token, :refresh_token
      )

      def initialize(transfer:, token:, phone:, verification_token:, password: nil,
        password_confirmation: nil, idempotency_key:, request:)
        @transfer = transfer
        @token = token.to_s
        @phone = phone
        @verification_token = verification_token
        @password = password
        @password_confirmation = password_confirmation
        @raw_idempotency_key = idempotency_key
        @request = request
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        validate_password!
        proof = Core::PhoneVerification::Verify.verify_proof(@verification_token)
        return failure(error(:transfer_recipient_mismatch, :forbidden)) unless proof

        request_digest = request_digest(key, proof)
        audit_key = "ticketing-ticket-transfer-guest-accepted-#{@transfer.id}-#{key.digest}"
        return replay(audit_key:, request_digest:) if Core::AuditLog.exists?(audit_key:)

        result = nil
        Ticketing::TicketTransfer.transaction do
          transfer = Ticketing::TicketTransfer.includes(:to_user).lock.find(@transfer.id)
          validation = validate(transfer, proof)
          if validation
            result = failure(validation)
            raise ActiveRecord::Rollback
          end

          ticket = load_ticket(transfer)
          validation = validate_ticket(ticket, transfer)
          if validation
            result = failure(validation)
            raise ActiveRecord::Rollback
          end

          revoke_pending_claims!(ticket)
          user = transfer.to_user
          ticket.update!(owner_user: user)
          replacement = Ticketing::CredentialGenerations::Replace.call(
            ticket:,
            target_mode: "group",
            reason: "ticket_transferred",
            assignments: {},
            idempotency_key: "ticket-transfer-#{transfer.id}-accept-guest"
          )
          if replacement.failure?
            result = replacement
            raise ActiveRecord::Rollback
          end

          set_password!(user)
          transfer.update!(status: "accepted", new_version: replacement.value.version, accepted_at: Time.current)
          audit = Core::Audit::Record.call(
            audit_key:,
            action: "ticketing.ticket_transfer.accepted",
            auditable_type: transfer.class.name,
            auditable_id: transfer.id,
            actor_type: user.class.name,
            actor_id: user.id,
            audited_changes: { status: "accepted", new_version: transfer.new_version },
            metadata: { ticket_id: transfer.ticket_id, request_digest: }
          )
          raise audit.error if audit.failure?

          published = Core::Outbox::Publish.call(
            topic: "ticketing",
            event_type: "ticketing.ticket_transfer.accepted",
            aggregate: transfer,
            payload: { transfer_id: transfer.id, ticket_id: transfer.ticket_id, version: transfer.new_version },
            idempotency_key: "ticketing-ticket-transfer-accepted-#{transfer.id}"
          )
          raise published.error if published.failure?

          result = success(build_result(transfer, user:))
        end
        result
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue ActiveRecord::RecordNotFound
        failure(error(:transfer_not_found, :not_found))
      rescue Core::Audit::ReplayConflict
        failure(error(:transfer_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:transfer_acceptance_failed, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def validate(transfer, proof)
        return error(:transfer_invalid, :not_found) unless digest_matches?
        return error(:transfer_not_pending, :conflict) unless transfer.status == "pending"
        return error(:transfer_expired, :conflict) if transfer.expires_at <= Time.current
        return error(:transfer_recipient_mismatch, :forbidden) unless proof[:user_id] == transfer.to_user_id.to_s
        return error(:transfer_recipient_mismatch, :forbidden) unless proof[:purpose] == "ticket_transfer"
        return error(:transfer_recipient_mismatch, :forbidden) unless proof[:phone_digest] == recipient_phone_digest(transfer)
        return error(:transfer_password_not_allowed, :conflict) if @password.present? && transfer.to_user.password_digest.present?

        nil
      end

      def validate_ticket(ticket, transfer)
        return error(:package_dead, :conflict) if ticket.package_dead?
        return error(:ticket_suspended, :conflict) if ticket.package_suspended?
        generation = ticket.current_credential_generation
        return error(:transfer_stale, :conflict) unless ticket.status == "active" &&
          ticket.credential_version == transfer.previous_version && generation&.status == "active" &&
          generation.version == ticket.credential_version
        return error(:transfer_cutoff_passed, :conflict) if cutoff_passed?(ticket)

        nil
      end

      def digest_matches?
        Ticketing::TicketTransfer.token_digest_for(token: @token) == @transfer.token_digest
      end

      def recipient_phone_digest(transfer)
        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(transfer.to_user.phone)
        Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized)
      end

      def request_digest(key, proof)
        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(@phone)
        password_digest = Core::KeyedDigest.digest(
          namespace: "ticketing-ticket-transfer-password",
          value: @password.to_s
        )
        Core::KeyedDigest.digest(
          namespace: "ticketing-ticket-transfer-guest-accept",
          value: [
            @transfer.id, key.digest, proof[:challenge_id],
            Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized), password_digest
          ].join(":")
        )
      end

      def validate_password!
        return if @password.blank?
        raise error(:transfer_password_invalid, :unprocessable_entity) if @password.to_s.length < 8
        raise error(:transfer_password_mismatch, :unprocessable_entity) unless @password == @password_confirmation
      end

      def set_password!(user)
        return if @password.blank?

        user.password = @password
        user.password_confirmation = @password_confirmation
        user.verified_at = Time.current
        user.save!
      end

      def replay(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by!(audit_key:)
        return failure(error(:transfer_conflict, :conflict)) unless audit.metadata["request_digest"] == request_digest

        transfer = Ticketing::TicketTransfer.find(audit.auditable_id)
        user = transfer.to_user
        success(build_result(transfer, user:))
      rescue ActiveRecord::RecordNotFound
        failure(error(:transfer_not_found, :not_found))
      end

      def build_result(transfer, user:)
        ticket = load_ticket(transfer)
        tokens = if user.password_digest.present? && user.verified_at.present?
          Core::AuthService.call(operation: :generate_auth_tokens, user:, request: @request).value
        end
        Result.new(
          transfer:,
          ticket:,
          ticket_view_url: Links::BrandedUrl.ticket(ticket),
          user:,
          access_token: tokens&.fetch(:access_token),
          refresh_token: tokens&.fetch(:refresh_token)
        )
      end

      def load_ticket(transfer)
        Ticketing::Ticket.includes(
          :event,
          :owner_user,
          :revocation,
          current_credential_generation: :credentials,
          event_product: { ticket_type: [], product_accesses: { event_date: :venue } }
        ).find(transfer.ticket_id)
      end

      def revoke_pending_claims!(ticket)
        ids = ticket.current_credential_generation.credentials.where(status: "pending_claim").select(:id)
        Ticketing::CredentialClaim.where(credential_id: ids, status: "pending")
          .update_all(status: "revoked", updated_at: Time.current)
      end

      def cutoff_passed?(ticket)
        dates = ticket.event_product.product_accesses.map(&:event_date).compact.reject { |date| date.status == "cancelled" }
        return false if dates.empty?

        seconds = ticket.event_product.ticket_type&.transfer_cutoff_seconds_before_start.to_i
        Time.current >= dates.map { |date| date.starts_at - seconds.seconds }.min
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:, errors:
        )
      end
    end
  end
end
