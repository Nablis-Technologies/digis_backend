# frozen_string_literal: true

module Links
  # Creation authorization for branded links. Resolution is public, but
  # creating a link remains tied to the creator and its target ownership.
  class ShortLinkPolicy < Core::ApplicationPolicy
    def create?(system: false)
      return true if system && record.canonical? && record.internal_target?
      return false unless user.present? && record.creator_id == user.id
      return true if user.super_admin?

      target_authorized?
    end

    private

    def target_authorized?
      return true if record.custom_url.present?

      case record.target_type
      when "event"
        Events::AuthorizationResolver.can_manage_catalog?(user, Events::Event.find(record.target_id))
      when "ticket"
        Ticketing::TicketPolicy.new(user, Ticketing::Ticket.find(record.target_id)).show?
      when "organization"
        Organizations::OrganizationPolicy.new(user, Organizations::Organization.find(record.target_id)).update?
      else
        false
      end
    rescue ActiveRecord::RecordNotFound
      false
    end
  end
end
