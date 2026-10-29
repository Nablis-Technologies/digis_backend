# frozen_string_literal: true

module Ticketing
  # The answer collection is private to the registration respondent. Controllers
  # scope the lookup first so an unauthorized registration is indistinguishable
  # from an unknown one; this policy is the explicit authorization contract.
  class RegistrationAnswerSetPolicy < Core::ApplicationPolicy
    def show_answers?
      user.present? && record.user_id == user.id
    end
  end
end
