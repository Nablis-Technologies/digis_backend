# frozen_string_literal: true

require "test_helper"
require "openssl"

module Core
  module Reauthentication
    class ThrottleTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      setup do
        @user = core_users(:attendee)
        @session_jti = "session-jti-for-throttle"
        @purpose = "attendee_export_request"
        @ip_address = "203.0.113.10"
      end

      test "allows five failed password checks per user-session and throttles the sixth" do
        with_memory_cache do
          5.times do
            assert_predicate throttle(failed_password: true), :success?
          end

          result = throttle(failed_password: true)

          assert_predicate result, :failure?
          assert_equal 429, result.error.status_code
        end
      end

      test "resets the user-session failure counter after fifteen minutes" do
        with_memory_cache do
          5.times { throttle(failed_password: true) }
          travel 15.minutes + 1.second

          assert_predicate throttle(failed_password: true), :success?
        end
      end

      test "allows thirty issuance attempts per IP and throttles the thirty-first" do
        with_memory_cache do
          30.times do
            assert_predicate throttle, :success?
          end

          result = throttle

          assert_predicate result, :failure?
          assert_equal 429, result.error.status_code
        end
      end

      test "resets the IP attempt counter after one hour" do
        with_memory_cache do
          30.times { throttle }
          travel 1.hour + 1.second

          assert_predicate throttle, :success?
        end
      end

      test "uses purpose-separated HMAC-shaped cache keys without raw identifiers" do
        cache = ActiveSupport::Cache::MemoryStore.new

        Rails.stubs(:cache).returns(cache)
        service = throttle_service
        assert_predicate service.call, :success?

        keys = cache.instance_variable_get(:@data).keys.map(&:to_s)
        assert_not_empty keys
        keys.each do |key|
          refute_includes key, @user.id.to_s
         refute_includes key, @session_jti
         refute_includes key, @ip_address
         assert_match(/[0-9a-f]{64}/, key)
         end

        derived_key = OpenSSL::HMAC.digest(
          "SHA256",
          Rails.application.secret_key_base,
          "core/reauthentication/throttle/issuance_attempt/#{@purpose}"
        )
        expected_digest = OpenSSL::HMAC.hexdigest("SHA256", derived_key, @ip_address)
        assert_equal "core/reauthentication/#{expected_digest}", service.send(:cache_key)
      end

      private

      def throttle(failed_password: false)
        throttle_service(failed_password:).call
      end

      def throttle_service(failed_password: false)
        Core::Reauthentication::Throttle.new(
          user: @user,
          session_jti: @session_jti,
          purpose: @purpose,
          ip_address: @ip_address,
          failed_password:
        )
      end

      def with_memory_cache
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        yield
      end
    end
  end
end
