# frozen_string_literal: true

module Ticketing
  # Public registration entry point for phone-confirmed guest checkout. The
  # command creates or reuses a passwordless shadow identity; payment and
  # credential issuance remain separate downstream workflows.
  class GuestRegistrationsController < Ticketing::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :ensure_idempotency_key_present

    def create
      ticket_type = public_ticket_type
      return render_not_found unless ticket_type

      answers = normalized_answers
      return render_invalid_submission if answers.nil?
      consents = normalized_consents
      return render_invalid_submission if consents.nil?

      result = Ticketing::Registrations::Submit.call(
        ticket_type:,
        actor: nil,
        phone: params.require(:phone),
        submission: registration_submission(answers, consents),
        audience_proof: { access_code: params[:access_code], invitation: params[:invitation_token] },
        idempotency_key:,
        guest: true,
        phone_confirmation: params[:phone_confirmation] == true || params[:phone_confirmation].to_s == "true",
        email: params[:email],
        full_name: params[:full_name]
      )
      return render_service_result(result) if result.failure?

      render_success(
        data: {
          registration: result.value.registration,
          next_action: { type: result.value.type }
        },
        status: :created,
        serializer_options: { registration: { serializer: Ticketing::RegistrationSerializer } }
      )
    end

    def claim_guest
      registration = Ticketing::Registration.find(params.require(:id))
      result = Ticketing::Registrations::ClaimGuest.call(
        registration:,
        phone: params.require(:phone),
        verification_token: params.require(:verification_token),
        password: params.require(:password),
        password_confirmation: params[:password_confirmation],
        idempotency_key:,
        request:
      )
      return render_service_result(result) if result.failure?

      render_success(
        data: {
          user: result.value.user,
          access_token: result.value.access_token,
          refresh_token: result.value.refresh_token
        },
        serializer_options: { user: { serializer: Core::UserAuthSerializer } }
      )
    end

    private

    def public_ticket_type
      Ticketing::TicketType
        .joins(event_product: :event)
        .merge(Events::Event.publicly_visible)
        .includes(event_product: :prices)
        .find_by(id: params[:ticket_type_id])
    end

    def registration_submission(answers, consents)
      Ticketing::RegistrationSubmission.new(
        package_quantity: params[:package_quantity],
        selected_event_date_id: params[:selected_event_date_id],
        answers:,
        consents:
      )
    end

    def normalized_answers
      raw_answers = params[:answers]
      return [] if raw_answers.nil?
      return unless raw_answers.is_a?(Array)

      raw_answers.map do |answer|
        attributes = answer.respond_to?(:to_unsafe_h) ? answer.to_unsafe_h : answer
        return unless attributes.is_a?(Hash)

        attributes.slice(
          "form_version_id", "question_key", "package_unit_number", "admission_position", "value"
        ).symbolize_keys
      end
    end

    def normalized_consents
      raw_consents = params[:consents]
      return [] if raw_consents.nil?
      return unless raw_consents.is_a?(Array)

      raw_consents.map do |consent|
        attributes = consent.respond_to?(:to_unsafe_h) ? consent.to_unsafe_h : consent
        return unless attributes.is_a?(Hash)

        attributes.slice(
          "consent_document_version_id", "request_uuid", "acceptance_method", "content_sha256",
          "package_unit_number", "admission_position", "idempotency_key"
        ).symbolize_keys
      end
    end

    def render_invalid_submission
      render_error(
        I18n.t("ticketing.forms.errors.invalid_submission"),
        status: :unprocessable_entity,
        code: "invalid_submission"
      )
    end

    def render_not_found
      render_error(I18n.t("errors.not_found", model: "ticket type"), status: :not_found)
    end
  end
end
