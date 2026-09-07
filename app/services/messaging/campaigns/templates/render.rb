# frozen_string_literal: true

module Messaging
  module Campaigns
    module Templates
      # Resolves one immutable template version for preview and delivery.
      class Render < Core::BaseService
        Rendered = Data.define(:subject, :body, :quantity)

        def initialize(template_version:, channel:, values: {})
          @template_version = template_version
          @channel = channel.to_s.strip.downcase
          @values = values.to_h.stringify_keys
        end

        def call
          return failure(error(:campaign_template_required)) unless @template_version.is_a?(CampaignTemplateVersion)
          return failure(error(:campaign_template_channel_mismatch)) unless template_channel == @channel

          Variables.validate!(@template_version.body)
          Variables.validate!(@template_version.subject) if @template_version.subject.present?
          body = interpolate(@template_version.body, escape_values: @channel == "email")
          subject = interpolate(@template_version.subject, escape_values: false)
          success(Rendered.new(subject:, body:, quantity: SmsSegmentCounter.units_for(channel: @channel, body:)))
        rescue Variables::UnknownVariable => exception
          failure(error(:campaign_template_unknown_variable, message: exception.message))
        rescue ArgumentError => exception
          failure(error(:campaign_template_invalid, message: exception.message))
        end

        private

        def template_channel
          @template_version.campaign_template.channel
        end

        def interpolate(content, escape_values:)
          Interpolator.call(content, values: @values, escape_values:)
        end

        def error(key, message: nil)
          Core::BusinessError.new(
            message || I18n.t("messaging.errors.#{key}"),
            code: key.to_s,
            status: :unprocessable_entity
          )
        end
      end
    end
  end
end
