# frozen_string_literal: true

module Messaging
  module Campaigns
    # Applies the active daily and monthly unit quotas in the policy timezone.
    class Quota < Core::BaseService
      def initialize(organization:, channel:, quantity:, timezone:, at: Time.current)
        @organization = organization
        @channel = channel
        @quantity = quantity
        @timezone = timezone
        @at = at.to_time
      end

      def call
        policy = policy_for
        return success(true) unless policy

        zone = ActiveSupport::TimeZone[policy.timezone]
        return failure(error(:campaign_quota_invalid)) unless zone

        day_start, day_end = window(zone, :day)
        month_start, month_end = window(zone, :month)
        return failure(error(:campaign_quota_exceeded)) if usage(day_start, day_end) + @quantity > policy.daily_limit
        return failure(error(:campaign_quota_exceeded)) if usage(month_start, month_end) + @quantity > policy.monthly_limit

        success(true)
      end

      private

      def policy_for
        CampaignVolumePolicy.where(channel: @channel, active: true)
          .where(organization_id: [ @organization.id, nil ])
          .order(Arel.sql("organization_id IS NULL"), updated_at: :desc).first
      end

      def window(zone, period)
        local = @at.in_time_zone(zone)
        start = period == :day ? local.beginning_of_day : local.beginning_of_month
        [ start.utc, (period == :day ? local.end_of_day : local.end_of_month).utc ]
      end

      def usage(start_time, end_time)
        # Quota measures launched send attempts, not drafted or delivered units.
        # Retaining canceled and failed launches prevents cancel/relaunch loops
        # from bypassing the organization's abuse and volume policy.
        Campaign.where(organization_id: @organization.id, channel: @channel)
          .where(launched_at: start_time..end_time).sum(:quoted_quantity)
      end

      def error(key)
        Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status: :unprocessable_entity)
      end
    end
  end
end
