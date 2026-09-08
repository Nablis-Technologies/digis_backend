# frozen_string_literal: true

require "securerandom"

module Links
  # Central URL boundary for branded links and signed direct fallbacks.
  class BrandedUrl
    SLUG_LENGTH = 6
    MAX_SLUG_ATTEMPTS = 5

    class << self
      def base_url
        config = Rails.application.config.x.short_links
        port = config.port.present? ? ":#{config.port.to_i}" : ""
        "#{config.protocol}://#{config.host}#{port}".delete_suffix("/")
      end

      def short_url(slug)
        "#{base_url}/#{slug.to_s.delete_prefix("/")}"
      end

      def ticket(ticket)
        return direct_ticket_url(ticket) unless enabled?

        short_url(canonical_ticket_link(ticket).slug)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ArgumentError, Core::Error
        direct_ticket_url(ticket)
      end

      def event(event)
        return direct_event_url(event) unless enabled?

        canonical_url(event) || direct_event_url(event)
      rescue ActiveRecord::RecordNotFound, ArgumentError, Core::Error
        direct_event_url(event)
      end

      def organization(organization)
        return direct_organization_url(organization) unless enabled?

        canonical_url(organization) || direct_organization_url(organization)
      rescue ActiveRecord::RecordNotFound, ArgumentError, Core::Error
        direct_organization_url(organization)
      end

      private

      def canonical_ticket_link(ticket)
        target = {
          target_type: "ticket",
          target_id: ticket.id,
          canonical: true
        }
        attempts = 0

        begin
          ShortLink.create!(target.merge(slug: ticket_slug, click_count: 0))
        rescue ActiveRecord::RecordNotUnique
          existing = ShortLink.find_by(**target) if attempts.zero?
          return existing if existing

          attempts += 1
          retry if attempts < MAX_SLUG_ATTEMPTS

          raise
        end
      end

      def canonical_url(record)
        link = ShortLink.find_by(
          canonical: true,
          target_type: record.class.name.demodulize.underscore,
          target_id: record.id
        )
        link && short_url(link.slug)
      end

      def ticket_slug
        "t-#{SecureRandom.alphanumeric(SLUG_LENGTH).downcase}"
      end

      def direct_ticket_url(ticket)
        token = Ticketing::GuestTicketViewToken.issue(ticket:)
        "#{public_app_url}/public/tickets/#{ticket.id}?view_token=#{ERB::Util.url_encode(token)}"
      end

      def direct_event_url(event)
        "#{public_app_url}/public/events/#{event.slug}"
      end

      def direct_organization_url(organization)
        "#{public_app_url}/organizations/#{organization.id}"
      end

      def public_app_url
        Rails.application.config.x.public_app_url.presence ||
          Rails.application.config.x.short_links.public_app_url.presence
      end

      def enabled?
        Rails.application.config.x.short_links.enabled
      end
    end
  end
end
