# frozen_string_literal: true

module Ticketing
  module ManualLookup
    # Provides a bounded, audited help-desk search. Ordinary gate scanners may
    # use PNR/phone recovery, but only trusted event managers or platform
    # administrators may search online identity data or select a name result.
    class OnlineSearch < Base
      SEARCH_LIMIT = 30
      SEARCH_WINDOW = 1.minute
      MAX_SEARCH_ROWS = 500

      def initialize(query:, selected_credential_id: nil, **options)
        super(**options)
        @query = query.to_s.strip
        @selected_credential_id = selected_credential_id
      end

      def call
        return failure(lookup_error(:help_desk_forbidden, :forbidden)) unless help_desk_authorized?
        return failure(reason_error) if reason_error
        return failure(lookup_error(:search_query_required, :bad_request)) if @query.blank?
        return failure(lookup_error(:lookup_rate_limited, :too_many_requests)) unless within_rate_limit?

        entries = matching_entries
        if entries.empty?
          record_lookup_audit!(lookup_via: "name", outcome: "not_found")
          return failure(lookup_error(:lookup_not_found, :not_found))
        end

        if selected_credential_id.present?
          entry = entries.find { |candidate| candidate.credential_id.to_s == selected_credential_id.to_s }
          return failure(lookup_error(:lookup_selection_invalid, :unprocessable_entity)) unless entry

          return consume_entry(entry, lookup_via: "name")
        end

        record_lookup_audit!(lookup_via: "name", outcome: "matches")
        result_for_matches("matches", entries)
      end

      private

      attr_reader :query

      def selected_credential_id
        @selected_credential_id
      end

      def reason_error
        valid_reason
      end

      def help_desk_authorized?
        Events::AuthorizationResolver.role_for(operator, event).in?(%i[super_admin admin owner manager])
      end

      def matching_entries
        digest = phone_hash(query)
        return phone_matches(digest) if digest

        text = query.downcase
        active_entries
          .includes(credential: :holder_user, ticket: :owner_user)
          .limit(MAX_SEARCH_ROWS)
          .to_a
          .select { |entry| searchable_identity(entry).include?(text) }
          .first(MAX_MATCHES)
      end

      def phone_matches(digest)
        active_entries
          .where("phone_hash = :digest OR owner_phone_hash = :digest", digest:)
          .order(:lookup_code)
          .limit(MAX_MATCHES)
          .to_a
      end

      def searchable_identity(entry)
        [
          entry.holder_name,
          entry.credential.holder_user&.email,
          entry.ticket.owner_user&.email
        ].compact.join(" ").downcase
      end

      def within_rate_limit?
        count = Rails.cache.increment(rate_limit_key, 1, expires_in: SEARCH_WINDOW)
        if count.nil?
          Rails.cache.write(rate_limit_key, 1, expires_in: SEARCH_WINDOW)
          count = 1
        end
        count <= SEARCH_LIMIT
      end

      def rate_limit_key
        digest = Core::KeyedDigest.digest(
          namespace: "ticketing-scanner-online-lookup",
          value: [ event.id, assignment.id, operator.id ].join(":")
        )
        "ticketing/scanner/online-lookup/#{digest}"
      end
    end
  end
end
