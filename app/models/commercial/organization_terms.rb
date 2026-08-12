# frozen_string_literal: true

module Commercial
  # Read-only organizer terms aggregate assembled from authoritative versions,
  # assignments, legal acceptance evidence, and event exceptions. It has no
  # table and therefore cannot be written through the organizer API.
  class OrganizationTerms
    extend ActiveModel::Naming
    include ActiveModel::Serialization

    attr_reader :organization, :current_version, :scheduled_version,
      :acceptance_history, :event_exceptions

    def initialize(organization:, current_version:, scheduled_version:, acceptance_history:, event_exceptions:)
      @organization = organization
      @current_version = current_version
      @scheduled_version = scheduled_version
      @acceptance_history = acceptance_history
      @event_exceptions = event_exceptions
    end

    def organization_id
      organization.id
    end
  end
end
