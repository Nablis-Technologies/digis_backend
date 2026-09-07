# frozen_string_literal: true

require "digest"

module Messaging
  # Public tokenized unsubscribe endpoint; it never exposes contact values.
  class CampaignUnsubscribesController < Messaging::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization only: %i[show create]

    def show
      guard = Campaigns::AbuseGuard.call(scope: "unsubscribe", identity: request.remote_ip, limit: 30)
      return render_error(guard.error.message, status: guard.error.status_code, code: guard.error.code) if guard.failure?

      payload = Campaigns::UnsubscribeToken.verify(params.require(:token))
      render_success(data: { valid: true, channel: payload.fetch("channel") })
    rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, ActiveRecord::RecordNotFound
      render_error(I18n.t("messaging.errors.invalid_unsubscribe_token"), status: :bad_request,
        code: "invalid_unsubscribe_token")
    end

    def create
      guard = Campaigns::AbuseGuard.call(scope: "unsubscribe", identity: request.remote_ip, limit: 30)
      return render_error(guard.error.message, status: guard.error.status_code, code: guard.error.code) if guard.failure?

      payload = Campaigns::UnsubscribeToken.verify(params.require(:token))
      organization = Organizations::Organization.find(payload.fetch("organization_id"))
      result = Campaigns::Suppressions::Record.call(
        organization:,
        channel: payload.fetch("channel"),
        channel_address_digest: payload.fetch("channel_address_digest"),
        source: "unsubscribe",
        reason: "public_link",
        idempotency_key: "messaging-unsubscribe-#{Digest::SHA256.hexdigest(params[:token])}"
      )
      return render_error(result.error.message, status: result.error.status_code, code: result.error.code) if result.failure?

      render_success(data: { channel: result.value.channel, status: "unsubscribed" })
    rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, ActiveRecord::RecordNotFound
      render_error(I18n.t("messaging.errors.invalid_unsubscribe_token"), status: :bad_request,
        code: "invalid_unsubscribe_token")
    end
  end
end
