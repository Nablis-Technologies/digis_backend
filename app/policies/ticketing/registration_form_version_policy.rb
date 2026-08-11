# frozen_string_literal: true

module Ticketing
  class RegistrationFormVersionPolicy < Core::ApplicationPolicy
    VERSION_FIELDS = %i[
      id registration_form_id version status published_by_id published_at created_at updated_at
    ].freeze
    QUESTION_FIELDS = %i[
      id registration_form_version_id key type response_scope sensitivity label help_text required
      position options validation_rules created_at updated_at
    ].freeze
    FIELDS = (VERSION_FIELDS + QUESTION_FIELDS).freeze

    def index? = organizer?
    def show? = organizer?
    def create? = organizer?
    def publish? = organizer?

    VISIBILITY = {
      index: { default: { fields: FIELDS, include: [ :questions ], association_fields: { questions: { fields: QUESTION_FIELDS } } }, admin: { fields: :all, include: :all } },
      show: { default: { fields: FIELDS, include: [ :questions ], association_fields: { questions: { fields: QUESTION_FIELDS } } }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [ :questions ], association_fields: { questions: { fields: QUESTION_FIELDS } } }, admin: { fields: :all, include: :all } },
      publish: { default: { fields: FIELDS, include: [ :questions ], association_fields: { questions: { fields: QUESTION_FIELDS } } }, admin: { fields: :all, include: :all } }
    }.freeze

    private

    def organizer?
      Events::AuthorizationResolver.can_manage_catalog?(user, record.registration_form.event)
    end
  end
end
