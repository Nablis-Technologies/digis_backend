# frozen_string_literal: true

module Links
  # Maps stable link target types to normal application routes without ever
  # constantizing database input. Target existence is checked on resolution.
  class TargetResolver
    TARGETS = {
      "event" => ->(id) { Events::Event.find(id); Rails.application.routes.url_helpers.event_path(id) },
      "ticket" => ->(id) { Ticketing::Ticket.find(id); "/tickets/#{id}" },
      "organization" => ->(id) { Organizations::Organization.find(id); Rails.application.routes.url_helpers.organization_path(id) }
    }.freeze

    def self.call(target_type, target_id)
      TARGETS.fetch(target_type.to_s).call(target_id)
    rescue KeyError, ActiveRecord::RecordNotFound
      raise Core::Error, I18n.t("links.errors.target_not_found")
    end
  end
end
