# frozen_string_literal: true

module Events
  # Determines whether an event may be published. The event's primary
  # organization must be verified, and the event must carry at least one
  # category. (A scheduled date becomes required once events_event_dates
  # exists — enforced in a later task.)
  class PublicationReadiness < Core::BaseService
    def initialize(event:)
      @event = event
    end

    def call
      unless @event.organization.verified?
        return failure(not_verified)
      end

      unless @event.event_categories.exists?
        return failure(missing_category)
      end

      unless @event.event_dates.exists?
        return failure(missing_date)
      end

      media = Events::Media::Readiness.call(event: @event)
      return failure(media_not_ready) unless media.success?

      success(@event)
    end

    private

    def not_verified
      Core::BusinessError.new(
        I18n.t("events.publish.errors.organization_not_verified"),
        code: "organization_not_verified",
        status: :unprocessable_entity
      )
    end

    def missing_category
      Core::BusinessError.new(
        I18n.t("events.publish.errors.missing_category"),
        code: "not_ready",
        status: :unprocessable_entity
      )
    end

    def missing_date
      Core::BusinessError.new(
        I18n.t("events.publish.errors.missing_date",
               default: "Event must have at least one scheduled date"),
        code: "not_ready",
        status: :unprocessable_entity
      )
    end

    def media_not_ready
      Core::BusinessError.new(
        I18n.t("events.event_media.errors.not_ready",
               default: "Event must have an attached, analyzed cover image with alt text"),
        code: "not_ready",
        status: :unprocessable_entity
      )
    end
  end
end
