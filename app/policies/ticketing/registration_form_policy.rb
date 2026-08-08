# frozen_string_literal: true

module Ticketing
  class RegistrationFormPolicy < Core::ApplicationPolicy
    FORM_FIELDS = %i[id event_id ticket_type_id name active created_at updated_at].freeze
    VERSION_FIELDS = %i[
      id registration_form_id version status published_by_id published_at created_at updated_at
    ].freeze
    QUESTION_FIELDS = %i[
      id registration_form_version_id key type response_scope sensitivity label help_text required
      position options validation_rules created_at updated_at
    ].freeze
    FIELDS = (FORM_FIELDS + VERSION_FIELDS + QUESTION_FIELDS).freeze

    def index? = organizer?
    def show? = organizer?
    def create? = organizer?
    def update? = organizer?
    def destroy? = organizer?

    VISIBILITY = {
      index: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      show: {
        default: {
          fields: FIELDS,
          include: [ :versions ],
          association_fields: {
            versions: { fields: VERSION_FIELDS,
                        association_fields: { questions: { fields: QUESTION_FIELDS } } }
          }
        },
        admin: { fields: :all, include: :all }
      },
      create: { default: { fields: FIELDS, include: [ :versions ] }, admin: { fields: :all, include: :all } },
      update: { default: { fields: FIELDS, include: [ :versions ] }, admin: { fields: :all, include: :all } },
      destroy: { default: { fields: [], include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.where(event_id: Events::AuthorizationResolver.manageable_catalog_events(user).select(:id))
      end
    end

    private

    def organizer?
      Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end
  end
end
