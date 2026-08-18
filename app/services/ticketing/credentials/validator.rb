# frozen_string_literal: true

module Ticketing
  module Credentials
    # Applies the shared scanner decision tree to verified QR claims or an
    # attendee-index claim set. It returns a decision code as a successful
    # service result because ordinary invalid admission attempts are expected
    # outcomes, not application exceptions.
    class Validator < Core::BaseService
      DECISIONS = %w[
        valid invalid_claims expired wrong_event wrong_access outside_window
        zone_required wrong_zone package_dead package_suspended revoked_generation
        revoked_credential already_used
      ].freeze

      def initialize(
        claims:, event_id:, product_access_id:, open_at:, close_at:, now: Time.current,
        allowed_zone_ids: [], access_zone_id: nil, assigned_zone_ids: [],
        package_dead: false, package_suspended: false, revoked_through_version: 0,
        credential_revoked: false, usage_limit: nil, active_use_counts: {}
      )
        @claims = claims
        @event_id = event_id.to_s
        @product_access_id = product_access_id.to_s
        @open_at = time_value(open_at)
        @close_at = time_value(close_at)
        @now = time_value(now)
        @allowed_zone_ids = Array(allowed_zone_ids).map(&:to_s)
        @access_zone_id = access_zone_id&.to_s
        @assigned_zone_ids = Array(assigned_zone_ids).map(&:to_s)
        @package_dead = package_dead
        @package_suspended = package_suspended
        @revoked_through_version = revoked_through_version.to_i
        @credential_revoked = credential_revoked
        @usage_limit = usage_limit&.to_i
        @active_use_counts = active_use_counts.to_h.transform_keys(&:to_s).transform_values(&:to_i)
      end

      def call
        claims = normalized_claims
        return decision(:invalid_claims) unless claims
        return decision(:invalid_claims) unless valid_claim_shape?(claims)
        return decision(:expired) if claims.exp <= @now
        return decision(:wrong_event) unless claims.eid == @event_id
        return decision(:wrong_access) unless claims.accesses.include?(@product_access_id)
        return decision(:outside_window) unless @now.between?(@open_at, @close_at)

        zone_decision = validate_zone
        return zone_decision if zone_decision
        return decision(:package_dead) if @package_dead
        return decision(:package_suspended) if @package_suspended
        return decision(:revoked_generation) if claims.v <= @revoked_through_version
        return decision(:revoked_credential) if @credential_revoked
        return decision(:already_used) if use_limit_reached?(claims)

        decision(:valid)
      end

      private

      def normalized_claims
        return @claims if @claims.is_a?(Ticketing::CredentialClaims)

        Ticketing::CredentialClaims.from_h(@claims)
      rescue ArgumentError, NoMethodError, TypeError
        nil
      end

      def valid_claim_shape?(claims)
        case claims.mode
        when "group"
          claims.slots.length == claims.entry_limit
        when "individual"
          claims.slots.length == 1 && claims.entry_limit == 1
        else
          false
        end
      end

      def validate_zone
        if @allowed_zone_ids.empty?
          return decision(:wrong_zone) if @access_zone_id
          return
        end

        return decision(:zone_required) unless @access_zone_id
        return decision(:wrong_zone) unless @allowed_zone_ids.include?(@access_zone_id)
        return decision(:wrong_zone) unless @assigned_zone_ids.include?(@access_zone_id)

        nil
      end

      def use_limit_reached?(claims)
        return false unless @usage_limit&.positive?

        claims.slots.any? do |position|
          @active_use_counts.fetch(position.to_s, 0) >= @usage_limit
        end
      end

      def decision(code)
        raise ArgumentError, I18n.t("ticketing.package_issuance.errors.invalid_validator_decision") unless DECISIONS.include?(code.to_s)

        success(code)
      end

      def time_value(value)
        value.respond_to?(:to_time) ? value.to_time.to_i : Integer(value)
      end
    end
  end
end
