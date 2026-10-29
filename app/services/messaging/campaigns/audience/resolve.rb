# frozen_string_literal: true

require "set"

module Messaging
  module Campaigns
    module Audience
      # Resolves a bounded, deduplicated set of channel-ready audience rows.
      class Resolve < Core::BaseService
        Candidate = Data.define(
          :channel, :channel_address, :channel_address_digest, :first_name, :last_name,
          :source_type, :source_id, :historical_basis
        )

        SOURCE_TYPES = %w[event registrants ticket_holders organization_subscribers contact_list].freeze
        HISTORICAL_BASES = %w[issued checked_in].freeze
        MAX_CANDIDATES = 10_000
        QUERY_LIMIT = MAX_CANDIDATES + 1

        def initialize(organization:, channel:, sources:)
          @organization = organization
          @channel = channel.to_s.strip.downcase
          @sources = Array(sources).map { |source| source.to_h.stringify_keys }
        end

        def call
          return failure(error(:campaign_audience_invalid)) unless Campaign::CHANNELS.include?(@channel)

          rows = []
          @sources.each do |source|
            rows.concat(rows_for(source))
            return failure(error(:campaign_audience_too_large)) if rows.length > MAX_CANDIDATES
          end
          users = users_for(rows)
          candidates = rows.filter_map { |row| candidate_for(row, users[row[:user_id]]) }
          success(deduplicate(candidates))
        rescue ActiveRecord::RecordNotFound
          failure(error(:campaign_audience_source_not_found))
        rescue ArgumentError => exception
          failure(error(:campaign_audience_invalid, message: exception.message))
        end

        private

        def rows_for(source)
          type = source.fetch("type")
          unless SOURCE_TYPES.include?(type)
            raise ArgumentError, I18n.t("messaging.errors.campaign_audience_source_unsupported")
          end

          case type
          when "event" then event_rows(source)
          when "registrants" then registrant_rows(source)
          when "ticket_holders" then ticket_rows(source)
          when "organization_subscribers" then subscriber_rows
          when "contact_list" then contact_rows(source)
          end
        end

        def event_rows(source)
          event = @organization.events.find(source.fetch("event_id"))
          basis = source.fetch("basis")
          raise ArgumentError, I18n.t("messaging.errors.campaign_audience_historical_basis_unsupported") unless HISTORICAL_BASES.include?(basis)

          if basis == "checked_in"
            Ticketing::CheckinLog.joins(:ticket).where(
              ticketing_tickets: { event_id: event.id }, result: "success"
            ).distinct.limit(QUERY_LIMIT).pluck("ticketing_tickets.owner_user_id", "ticketing_tickets.id").map do |user_id, ticket_id|
              row(user_id:, source_type: "event", source_id: event.id, historical_basis: basis,
                dedupe_id: ticket_id)
            end
          else
            Ticketing::Ticket.where(event_id: event.id, status: %w[active suspended refunded]).limit(QUERY_LIMIT).pluck(
              :owner_user_id, :id
            ).map do |user_id, ticket_id|
              row(user_id:, source_type: "event", source_id: event.id, historical_basis: basis,
                dedupe_id: ticket_id)
            end
          end
        end

        def registrant_rows(source)
          event = @organization.events.find(source.fetch("event_id"))
          Ticketing::Registration.where(event_id: event.id, status: Ticketing::Registration::STATUSES - %w[rejected cancelled expired]).limit(QUERY_LIMIT)
            .pluck(:user_id, :id).map do |user_id, registration_id|
              row(user_id:, source_type: "registration", source_id: registration_id, dedupe_id: registration_id)
            end
        end

        def ticket_rows(source)
          event = @organization.events.find(source.fetch("event_id"))
          Ticketing::Ticket.where(event_id: event.id, status: %w[active suspended]).limit(QUERY_LIMIT).pluck(:owner_user_id, :id).map do |user_id, ticket_id|
            row(user_id:, source_type: "ticket", source_id: ticket_id, dedupe_id: ticket_id)
          end
        end

        def subscriber_rows
          Core::Follow.where(followable_type: "Organizations::Organization", followable_id: @organization.id)
            .limit(QUERY_LIMIT).pluck(:follower_id, :id).map do |user_id, follow_id|
              row(user_id:, source_type: "organization_subscriber", source_id: follow_id, dedupe_id: follow_id)
            end
        end

        def contact_rows(source)
          list = CampaignContactList.where(organization_id: @organization.id, status: "active").find(source.fetch("id"))
          list.entries.where(status: "active").limit(QUERY_LIMIT).to_a.filter_map do |entry|
            address = ChannelAddress.normalize(channel: @channel, value: @channel == "sms" ? entry.phone_number : entry.email)
            digest = @channel == "sms" ? entry.phone_digest : entry.email_digest
            next if address.blank? || digest.blank?

            row(channel_address: address, channel_address_digest: digest, first_name: entry.first_name,
              last_name: entry.last_name, source_type: "contact_list", source_id: list.id,
              dedupe_id: entry.id)
          end
        end

        def users_for(rows)
          ids = rows.filter_map { |candidate| candidate[:user_id] }.uniq
          Core::User.where(id: ids).select(:id, :phone, :email).index_by(&:id)
        end

        def candidate_for(row, user)
          return Candidate.new(**row.slice(:channel, :channel_address, :channel_address_digest,
            :first_name, :last_name, :source_type, :source_id, :historical_basis)) if row[:channel_address].present?
          return if user.blank?

          address = ChannelAddress.normalize(channel: @channel, value: @channel == "sms" ? user.phone : user.email)
          return if address.blank?

          Candidate.new(
            channel: @channel,
            channel_address: address,
            channel_address_digest: digest_for(address),
            first_name: nil,
            last_name: nil,
            source_type: row[:source_type],
            source_id: row[:source_id],
            historical_basis: row[:historical_basis]
          )
        end

        def deduplicate(candidates)
          candidates.group_by(&:channel_address_digest).values.map do |matches|
            matches.min_by { |candidate| [ candidate.source_type, candidate.source_id.to_s ] }
          end.sort_by { |candidate| [ candidate.channel_address_digest, candidate.source_type, candidate.source_id.to_s ] }
        end

        def row(user_id: nil, channel_address: nil, channel_address_digest: nil, first_name: nil, last_name: nil,
          source_type:, source_id:, historical_basis: nil, dedupe_id:)
          {
            user_id:, channel: @channel, channel_address:, channel_address_digest:, first_name:, last_name:,
            source_type:, source_id:, historical_basis:, dedupe_id:
          }
        end

        def digest_for(address)
          ChannelAddress.digest(channel: @channel, value: address)
        end

        def error(key, message: nil)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s,
            status: :unprocessable_entity)
        end
      end
    end
  end
end
