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

      streaming = streaming_readiness
      return streaming if streaming.failure?

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
        I18n.t("events.publish.errors.missing_date"),
        code: "not_ready",
        status: :unprocessable_entity
      )
    end

    def media_not_ready
      Core::BusinessError.new(
        I18n.t("events.event_media.errors.not_ready"),
        code: "not_ready",
        status: :unprocessable_entity
      )
    end

    def streaming_readiness
      streams = Events::EventStream
        .includes(event_date: :event)
        .where(event_date_id: @event.event_dates.select(:id))
        .to_a
      accesses = Catalog::ProductAccess
        .includes(:event_product, :event_date)
        .where(event_product_id: @event.event_products.select(:id), type: "stream")
        .to_a

      streams.each { |stream| Streaming::Providers::Registry.for(stream) }
      return success(@event) if accesses.empty?

      accesses.each do |access|
        stream = streams.find { |candidate| candidate.event_date_id == access.event_date_id }
        return failure(streaming_access_missing) unless stream
        return failure(streaming_protection_unsupported) if protection_rank(stream.access_protection) < protection_rank(access.required_access_protection)
      end

      success(@event)
    rescue Streaming::Providers::UnknownProvider
      failure(streaming_provider_unavailable)
    rescue Streaming::Providers::InvalidConfiguration
      failure(streaming_protection_unsupported)
    end

    def protection_rank(protection)
      { "public" => 0, "soft_gated" => 1, "signed" => 2 }.fetch(protection.to_s, -1)
    end

    def streaming_provider_unavailable
      streaming_error(:streaming_provider_unavailable)
    end

    def streaming_protection_unsupported
      streaming_error(:streaming_protection_unsupported)
    end

    def streaming_access_missing
      streaming_error(:streaming_access_missing)
    end

    def streaming_error(key)
      Core::BusinessError.new(
        I18n.t("streaming.errors.#{key}"),
        code: key.to_s,
        status: :unprocessable_entity
      )
    end
  end
end
