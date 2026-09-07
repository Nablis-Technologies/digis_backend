# frozen_string_literal: true

module Messaging
  module Campaigns
    module Links
      # Associates a campaign with an existing branded custom-URL short link.
      class Create < Core::BaseService
        def initialize(campaign:, actor:, destination_url:, name: "Campaign destination")
          @campaign = campaign
          @actor = actor
          @destination_url = destination_url
          @name = name
        end

        def call
          return failure(error(:unauthorized, status: :forbidden)) unless Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)

          slug = "campaign-#{@campaign.id.delete("-")[0, 20]}-#{slug_suffix}"
          short_link_result = ::Links::Create.call(
            creator: @actor,
            slug:,
            custom_url: @destination_url,
            utm_campaign: @campaign.id,
            utm_source: @campaign.channel,
            utm_medium: "messaging_campaign"
          )
          short_link = if short_link_result.success?
            short_link_result.value
          elsif short_link_result.error.code.to_s == "slug_taken"
            existing_short_link(slug)
          else
            return failure(short_link_result.error)
          end
          return failure(error(:campaign_link_invalid)) unless short_link

          success(CampaignLink.find_or_create_by!(campaign: @campaign, short_link:) do |link|
            link.channel = @campaign.channel
            link.name = @name
          end)
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:campaign_link_invalid, message: exception.message))
        rescue ActiveRecord::RecordNotFound
          failure(error(:campaign_link_invalid))
        end

      private

      def slug_suffix
        Core::KeyedDigest.digest(
          namespace: "messaging-campaign-link-slug", value: "#{@campaign.id}:#{@name}:#{@destination_url}"
        )[0, 16]
      end

      def existing_short_link(slug)
        link = ::Links::ShortLink.find_by!(slug:)
        return link if link.custom_url == @destination_url && link.utm_campaign == @campaign.id &&
          link.utm_source == @campaign.channel && link.utm_medium == "messaging_campaign"

        nil
      end

      def error(key, message: nil, status: :unprocessable_entity)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
        end
      end
    end
  end
end
