# frozen_string_literal: true

module Ticketing
  class RegistrationAnswersController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::IdempotencyKeyResolver

    before_action :find_answer
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
  end
end
