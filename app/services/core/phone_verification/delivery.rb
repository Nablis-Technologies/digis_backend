# frozen_string_literal: true

module Core
  module PhoneVerification
    # Provider-neutral OTP delivery seam. Live deployments inject a sender;
    # tests and preview can inject a deterministic sender without retaining the
    # code in application state.
    class Delivery < Core::BaseService
      def initialize(phone:, code:, challenge:)
        @phone = phone
        @code = code
        @challenge = challenge
      end

      def call
        sender = Rails.application.config.x.phone_verification_sender
        return failure(error(:delivery_unavailable, :failed_dependency)) unless sender.respond_to?(:call)

        sender.call(phone:, code:, challenge:)
        success(challenge)
      rescue StandardError => exception
        failure(error(:delivery_failed, :failed_dependency, meta: { cause: exception.class.name }))
      end

      private

      attr_reader :phone, :code, :challenge

      def error(key, status, meta: nil)
        Core::BusinessError.new(
          I18n.t("auth.phone_verification.errors.#{key}"),
          code: key.to_s, status:, meta:
        )
      end
    end
  end
end
