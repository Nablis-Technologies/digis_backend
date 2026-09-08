# frozen_string_literal: true

require "json"

module Ticketing
  # Signs a read-only public ticket view token. It carries only an opaque
  # ticket identity, the credential generation version, and a hard expiry; the
  # controller revalidates the live ticket before returning any QR material.
  class GuestTicketViewToken < Core::BaseService
    PURPOSE = "ticketing.guest_ticket_view"
    RETENTION = 30.days
    Result = Data.define(:ticket_id, :credential_version, :expires_at)

    def self.issue(ticket:)
      new(ticket:).issue
    end

    def self.verify(token)
      new(token:).verify
    end

    def initialize(ticket: nil, token: nil)
      @ticket = ticket
      @token = token
    end

    def issue
      expiry = event_end + RETENTION
      verifier.generate(
        {
          "ticket_id" => ticket.id.to_s,
          "credential_version" => ticket.credential_version.to_i,
          "expires_at" => expiry.iso8601(6)
        },
        purpose: PURPOSE,
        expires_at: expiry
      )
    end

    def verify
      payload = verifier.verify(token, purpose: PURPOSE).deep_stringify_keys
      expires_at = Time.iso8601(payload.fetch("expires_at"))
      raise ArgumentError if expires_at <= Time.current

      success(Result.new(
        ticket_id: payload.fetch("ticket_id").to_s,
        credential_version: Integer(payload.fetch("credential_version")),
        expires_at:
      ))
    rescue ActiveSupport::MessageVerifier::InvalidSignature,
           ActiveSupport::MessageVerifier::InvalidMessage,
           ActiveSupport::MessageVerifier::InvalidMetadata,
           KeyError,
           ArgumentError,
           TypeError
      failure(invalid_error)
    end

    private

    attr_reader :ticket, :token

    def event_end
      ends_at = ticket.event_product.product_accesses.filter_map { |access| access.event_date&.ends_at }
      ends_at.max || raise(ArgumentError, I18n.t("ticketing.guest_ticket.errors.expiry_unavailable"))
    end

    def verifier
      ActiveSupport::MessageVerifier.new(
        Rails.application.secret_key_base,
        digest: "SHA256",
        serializer: JSON
      )
    end

    def invalid_error
      Core::BusinessError.new(
        I18n.t("ticketing.guest_ticket.errors.invalid_view_token"),
        code: "invalid_guest_ticket_view",
        status: :not_found
      )
    end
  end
end
