# frozen_string_literal: true

module Ticketing
  # Attendee-facing registration submission and privacy-scoped retrieval.
  class RegistrationsController < Ticketing::ApplicationController
    before_action :ensure_idempotency_key_present, only: %i[create release]
    before_action :load_registration, only: :release

    def create
      ticket_type = Ticketing::TicketType.includes(event_product: :prices).find(params[:ticket_type_id])
      authorize Registration.new(user: current_user), :create?
      answers = normalized_answers
      return render_invalid_submission if answers.nil?
      consents = normalized_consents
      return render_invalid_submission if consents.nil?

      result = Ticketing::Registrations::Submit.call(
        ticket_type:,
        actor: current_user,
        phone: params.require(:phone),
        submission: registration_submission(answers, consents),
        audience_proof: { access_code: params[:access_code], invitation: params[:invitation_token] },
        idempotency_key:
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

    def show
      registration = Ticketing::Registration.includes(:event).find(params[:id])
      authorize registration
      render_success(data: registration, serializer_options: { serializer: Ticketing::RegistrationSerializer })
    end

    def release
      authorize @registration, :release?
      result = Ticketing::Registrations::ReleasePending.call(
        registration: @registration,
        buyer: current_user,
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::RegistrationSerializer }
      )
    end

    private

    def load_registration
      @registration = Ticketing::Registration.find(params[:id])
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
  end
end
