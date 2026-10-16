# frozen_string_literal: true

module Ticketing
  # Shows an authorized answer and appends attendee or organizer corrections.
  # It delegates mutation rules, retention checks, and replay protection to the
  # revision command instead of exposing direct answer updates.
  class RegistrationAnswersController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::IdempotencyKeyResolver

    before_action :find_answer, only: %i[show revise]
    before_action :ensure_idempotency_key_present, only: :revise

    def show
      authorize @answer
      render_success(data: @answer, serializer_options: serializer_options)
    end

    def revise
      authorize @answer, :revise?
      result = Ticketing::Answers::Revise.call(
        answer: @answer,
        revised_by: current_user,
        value: params[:value],
        source: params.require(:source),
        reason_code: params[:reason_code],
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::RegistrationAnswerRevisionSerializer }
      )
    end

    def answers
      response.set_header("Cache-Control", "private, no-store")
      @registration = respondent_registrations.find_by(id: params[:id])
      return render_registration_not_found unless @registration

      authorize @registration, :show_answers?, policy_class: Ticketing::RegistrationAnswerSetPolicy
      cutoff = Ticketing::Answers::CorrectionWindow.call(registration: @registration)
      correction_window_open = cutoff.nil? || Time.current <= cutoff
      answer_rows = @registration.form_submissions.flat_map(&:answers)
        .sort_by { |answer| answer_order(answer) }
        .map do |answer|
          Ticketing::EditableRegistrationAnswerSerializer.new(
            answer, correction_window_open:
          ).attributes
        end

      render_success(
        data: {
          registration_id: @registration.id,
          answers_editable_until: cutoff,
          can_edit_answers: answer_rows.any? { |answer| answer[:editable] },
          answers: answer_rows
        }
      )
    end

    private

    def find_answer
      @answer = Ticketing::RegistrationAnswer
        .includes(
          :registration_question,
          registration_form_submission: { registration: :event }
        )
        .find(params[:id])
    end

    def serializer_options
      { serializer: Ticketing::RegistrationAnswerSerializer }
    end

    def respondent_registrations
      Ticketing::Registration
        .where(user_id: current_user.id)
        .includes(
          { form_submissions: { answers: [ :registration_question, :revisions ] } }
        )
    end

    def answer_order(answer)
      [ answer.registration_question.position, answer.package_unit_number.to_i,
        answer.admission_position.to_i, answer.id ]
    end

    def render_registration_not_found
      render_error(I18n.t("errors.not_found", model: "registration"), status: :not_found)
    end
  end
end
