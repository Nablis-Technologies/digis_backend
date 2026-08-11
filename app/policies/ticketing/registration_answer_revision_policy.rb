# frozen_string_literal: true

module Ticketing
  class RegistrationAnswerRevisionPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id registration_answer_id revision_number revised_by_id source reason_code revised_at
      erased_at created_at updated_at
    ].freeze

    def show? = answer_policy.show?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    private

    def answer_policy
      Ticketing::RegistrationAnswerPolicy.new(user, record.registration_answer)
    end
  end
end
