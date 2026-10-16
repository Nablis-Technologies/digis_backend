# frozen_string_literal: true

require "time"

module Events
  module Public
    # Validates public discovery filters and applies them to a public-visible
    # event relation before pagination or availability projection.
    class Search < Core::BaseService
      SORTS = %w[newest soonest price_asc price_desc].freeze
      MAX_PRICE_MINOR = 9_223_372_036_854_775_807
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      InvalidFilter = Class.new(StandardError)

      Filters = Data.define(
        :query, :category, :city, :date_from, :date_to, :organization_id,
        :venue_id, :artist_id, :sort, :currency, :min_price_minor, :max_price_minor
      )
      Result = Data.define(:scope, :currency)

      def initialize(scope:, parameters:, at: Time.current)
        @scope = scope
        @parameters = parameters
        @at = at.to_time.utc
      end

      def call
        filters = normalized_filters
        relation = apply_filters(@scope, filters)
        success(Result.new(scope: apply_sort(relation, filters), currency: filters.currency))
      rescue InvalidFilter
        failure(invalid_filter)
      end

      private

      attr_reader :at

      def normalized_filters
        source = @parameters.respond_to?(:to_unsafe_h) ? @parameters.to_unsafe_h : @parameters.to_h
        source = source.stringify_keys
        filters = Filters.new(
          query: text(source["q"], maximum: 120, minimum: 2),
          category: text(source["category"], maximum: 100)&.downcase,
          city: text(source["city"], maximum: 100)&.downcase,
          date_from: timestamp(source["date_from"]),
          date_to: timestamp(source["date_to"]),
          organization_id: uuid(source["organization_id"]),
          venue_id: uuid(source["venue_id"]),
          artist_id: uuid(source["artist_id"]),
          sort: text(source["sort"], maximum: 20) || "newest",
          currency: text(source["currency"], maximum: 3)&.upcase,
          min_price_minor: integer(source["min_price_minor"]),
          max_price_minor: integer(source["max_price_minor"])
        )
        raise InvalidFilter unless SORTS.include?(filters.sort)
        raise InvalidFilter if filters.currency.present? && !filters.currency.match?(/\A[A-Z]{3}\z/)
        if (filters.min_price_minor || filters.max_price_minor || filters.sort.start_with?("price_")) && filters.currency.blank?
          raise InvalidFilter
        end
        if filters.min_price_minor && filters.max_price_minor && filters.min_price_minor > filters.max_price_minor
          raise InvalidFilter
        end
        raise InvalidFilter if filters.date_from && filters.date_to && filters.date_from >= filters.date_to

        filters
      end

      def text(value, maximum:, minimum: 1)
        return if value.nil? || value == ""
        raise InvalidFilter unless value.is_a?(String)

        normalized = value.strip
        return if normalized.empty?
        raise InvalidFilter unless normalized.length.between?(minimum, maximum)
        normalized
      end

      def timestamp(value)
        return if value.nil? || value == ""
        raise InvalidFilter unless value.is_a?(String)

        Time.iso8601(value).utc
      rescue ArgumentError
        raise InvalidFilter
      end

      def uuid(value)
        return if value.nil? || value == ""
        raise InvalidFilter unless value.is_a?(String) && UUID_PATTERN.match?(value)

        value.downcase
      end

      def integer(value)
        return if value.nil? || value == ""
        return valid_minor_amount(value) if value.is_a?(Integer)
        raise InvalidFilter unless value.is_a?(String) && value.match?(/\A\d+\z/)

        valid_minor_amount(Integer(value, 10))
      rescue ArgumentError
        raise InvalidFilter
      end

      def valid_minor_amount(value)
        raise InvalidFilter unless value.between?(0, MAX_PRICE_MINOR)
        value
      end

      def apply_filters(scope, filters)
        relation = filter_query(scope, filters.query)
        relation = filter_category(relation, filters.category)
        relation = filter_organization(relation, filters.organization_id)
        relation = filter_artist(relation, filters.artist_id, filters)
        relation = filter_dates(relation, filters)
        filter_currency(relation, filters)
      end

      def filter_query(scope, query)
        return scope unless query

        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
        scope.where("events_events.title ILIKE :pattern OR events_events.description ILIKE :pattern", pattern:)
      end

      def filter_category(scope, slug)
        return scope unless slug

        event_ids = Events::EventCategory.joins(:category)
          .where(events_categories: { slug:, active: true }).select(:event_id)
        scope.where(id: event_ids)
      end

      def filter_organization(scope, organization_id)
        return scope unless organization_id

        collaborators = Events::EventOrganization.where(
          organization_id:, status: "active"
        ).select(:event_id)
        scope.where(
          "events_events.organization_id = :organization_id OR events_events.id IN (#{collaborators.to_sql})",
          organization_id:
        )
      end

      def filter_artist(scope, artist_id, filters)
        return scope unless artist_id

        participants = Events::EventParticipant.where(artist_id:)
        if date_filter?(filters)
          event_level = participants.where(event_date_id: nil)
          on_matching_date = participants.where(event_date_id: matching_dates(filters).select(:id))
          participants = event_level.or(on_matching_date)
        end
        scope.where(id: participants.select(:event_id))
      end

      def filter_dates(scope, filters)
        return scope unless date_filter?(filters)

        scope.where(id: matching_dates(filters).select(:event_id))
      end

      def matching_dates(filters)
        dates = Events::EventDate.where.not(status: "cancelled")
        dates = dates.where(venue_id: filters.venue_id) if filters.venue_id
        dates = dates.joins(:venue).where("LOWER(events_venues.city) = ?", filters.city) if filters.city
        dates = dates.where("events_event_dates.ends_at > ?", filters.date_from) if filters.date_from
        dates = dates.where("events_event_dates.starts_at < ?", filters.date_to) if filters.date_to
        dates
      end

      def date_filter?(filters)
        filters.venue_id || filters.city || filters.date_from || filters.date_to
      end

      def filter_currency(scope, filters)
        return scope unless filters.currency

        scope.where(id: public_prices(filters).select("catalog_event_products.event_id"))
      end

      def public_prices(filters, apply_bounds: true)
        prices = Catalog::ProductPrice.joins(event_product: :ticket_type)
          .where(
            catalog_event_products: { status: "active", type: "ticket" },
            ticketing_ticket_types: { audience: "public" },
            catalog_product_prices: { currency: filters.currency }
          )
          .where("catalog_product_prices.active_from <= ?", at)
          .where("catalog_product_prices.active_to IS NULL OR catalog_product_prices.active_to > ?", at)
        prices = prices.where("catalog_product_prices.amount_minor >= ?", filters.min_price_minor) if
          apply_bounds && filters.min_price_minor
        prices = prices.where("catalog_product_prices.amount_minor <= ?", filters.max_price_minor) if
          apply_bounds && filters.max_price_minor
        prices
      end

      def apply_sort(scope, filters)
        case filters.sort
        when "soonest"
          dates = matching_dates(filters).where(status: "scheduled")
            .where("events_event_dates.starts_at > ?", at)
            .where("events_event_dates.event_id = events_events.id")
            .select("MIN(events_event_dates.starts_at)")
          scope.order(Arel.sql("(#{dates.to_sql}) ASC NULLS LAST"), id: :desc)
        when "price_asc", "price_desc"
          prices = public_prices(filters, apply_bounds: false)
            .group("catalog_event_products.event_id")
            .reselect("catalog_event_products.event_id, MIN(catalog_product_prices.amount_minor) AS min_price_minor")
          direction = filters.sort == "price_asc" ? "ASC" : "DESC"
          scope.joins("INNER JOIN (#{prices.to_sql}) public_event_prices ON public_event_prices.event_id = events_events.id")
            .order(Arel.sql("public_event_prices.min_price_minor #{direction}"), id: :desc)
        else
          scope.order(published_at: :desc, id: :desc)
        end
      end

      def invalid_filter
        Core::BusinessError.new(
          I18n.t("event.errors.invalid_public_event_filter"),
          code: "invalid_public_event_filter", status: :unprocessable_entity
        )
      end
    end
  end
end
