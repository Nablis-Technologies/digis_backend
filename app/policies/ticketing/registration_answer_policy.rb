# frozen_string_literal: true

module Ticketing
  class RegistrationAnswerPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id registration_form_submission_id registration_question_id question_key_snapshot
      question_type_snapshot response_scope_snapshot question_label_snapshot package_unit_number
      admission_position admission_slot_id answered_at erased_at created_at updated_at
    ].freeze

    def show? = organizer? || respondent?
    def revise? = organizer? || respondent?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      revise: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    private

    def organizer?
      registration = record.registration_form_submission&.registration
      registration && Events::AuthorizationResolver.can_manage_catalog?(user, registration.event)
    end

    def respondent?
      submission = record.registration_form_submission
      registration = submission&.registration
      registration && registration.user_id == user&.id
    end
  end
end
