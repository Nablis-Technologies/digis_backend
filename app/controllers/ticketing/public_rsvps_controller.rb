# frozen_string_literal: true

module Ticketing
  # Public RSVP boundary for free ticket products. Authentication is optional:
  # guests prove phone ownership first, while signed-in attendees use their
  # current identity and the shared registration workflow.
  class PublicRsvpsController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :authenticate_if_present
    before_action :ensure_idempotency_key_present
    before_action :set_no_store

    def request_otp
      event = public_event
      ticket_type = public_ticket_type(event)
      return render_not_found unless event && ticket_type

      result = Ticketing::Rsvps::RequestOtp.call(
        event:,
        ticket_type:,
        phone: rsvp_payload.require(:phone),
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      challenge = result.value.challenge
      render_success(
        data: { challenge_id: challenge.id, status: challenge.status, expires_at: challenge.expires_at },
        status: :created
      )
    rescue ActionController::ParameterMissing => error
      render_invalid_request(error)
    end

    def create
      event = public_event
      ticket_type = public_ticket_type(event)
      return render_not_found unless event && ticket_type

      result = Ticketing::Rsvps::Submit.call(
        event:,
        ticket_type:,
        actor: current_user,
        phone: rsvp_payload[:phone],
        verification_token: rsvp_payload[:verification_token],
        submission: registration_submission,
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      outcome = result.value
      render_success(
        data: {
          registration: outcome.registration,
          next_action: { type: outcome.next_action },
          tickets: outcome.tickets
        },
        status: outcome.status,
        serializer_options: {
          registration: { serializer: Ticketing::RegistrationSerializer },
          tickets: { serializer: Ticketing::TicketWalletSerializer }
        }
      )
    rescue ActionController::ParameterMissing => error
      render_invalid_request(error)
    end

    private

    def authenticate_if_present
      return unless request.headers["Authorization"].present?

      authenticate_user
    end

    def rsvp_payload
      params.require(:rsvp)
    end

    def public_event
      Events::Event.publicly_visible.find_by(slug: params.require(:event_slug))
    end

    def public_ticket_type(event)
      return unless event

      Ticketing::TicketType
        .joins(:event_product)
        .where(catalog_event_products: { event_id: event.id })
        .includes(event_product: [ :event, :prices, { product_accesses: { event_date: :venue } } ])
        .find_by(id: rsvp_payload[:ticket_type_id])
    end

    def registration_submission
      Ticketing::RegistrationSubmission.new(
        package_quantity: rsvp_payload[:package_quantity].presence || 1,
        selected_event_date_id: rsvp_payload[:selected_event_date_id],
        answers: normalized_entries(rsvp_payload[:answers], %w[
          form_version_id question_key package_unit_number admission_position value
        ]),
        consents: normalized_entries(rsvp_payload[:consents], %w[
          consent_document_version_id request_uuid acceptance_method content_sha256
          package_unit_number admission_position idempotency_key
        ])
      )
    end

    def normalized_entries(entries, allowed_keys)
      return [] if entries.nil?
      return nil unless entries.is_a?(Array)

      entries.map do |entry|
        attributes = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
        return nil unless attributes.is_a?(Hash)

        attributes.slice(*allowed_keys).symbolize_keys
      end
    end

    def render_not_found
      render_error(I18n.t("errors.not_found", model: "RSVP product"), status: :not_found, code: "rsvp_product_not_found")
    end

    def render_invalid_request(error = nil)
      param = error&.param || "rsvp"
      render_error(I18n.t("errors.parameter_missing", param:), status: :bad_request, code: "invalid_request")
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end
  end
end
