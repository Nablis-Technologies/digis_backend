# frozen_string_literal: true

require "test_helper"

module Core
  class InvitationThrottleTest < ActiveSupport::TestCase
    test "limits attempts independently by actor" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      limit = Core::InvitationThrottle::LIMIT

      limit.times do |index|
        assert_predicate throttle(actor_id: "user-1", contact_digest: digest("contact-#{index}"),
          ip_address: "192.0.2.#{index + 1}"), :success?
      end

      result = throttle(actor_id: "user-1", contact_digest: digest("last-contact"), ip_address: "192.0.2.99")
      assert_predicate result, :failure?
      assert_equal "rate_limited", result.error.code
      assert_equal :too_many_requests, result.error.status_code
    end

    test "limits attempts independently by contact" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      contact_digest = digest("same-contact")

      Core::InvitationThrottle::LIMIT.times do |index|
        assert_predicate throttle(actor_id: "user-#{index}", contact_digest:, ip_address: "192.0.2.#{index + 1}"),
          :success?
      end

      result = throttle(actor_id: "another-user", contact_digest:, ip_address: "192.0.2.99")
      assert_equal "rate_limited", result.error.code
    end

    test "limits attempts independently by source IP" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      source_ip = "192.0.2.10"

      Core::InvitationThrottle::LIMIT.times do |index|
        assert_predicate throttle(actor_id: "user-#{index}", contact_digest: digest("contact-#{index}"),
          ip_address: source_ip), :success?
      end

      result = throttle(actor_id: "another-user", contact_digest: digest("another-contact"), ip_address: source_ip)
      assert_equal "rate_limited", result.error.code
    end

    test "supports a contact-only throttle check after invitation token lookup" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      contact_digest = digest("verified-invitation-contact")

      Core::InvitationThrottle::LIMIT.times do
        result = Core::InvitationThrottle.call(actor_id: nil, contact_digest:, ip_address: nil)
        assert_predicate result, :success?
      end

      result = Core::InvitationThrottle.call(actor_id: nil, contact_digest:, ip_address: nil)
      assert_equal "rate_limited", result.error.code
    end

    test "uses keyed cache keys without raw identifiers" do
      cache = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(cache)
      throttle(actor_id: "user-secret", contact_digest: "phone-secret", ip_address: "203.0.113.55")

      keys = cache.instance_variable_get(:@data).keys.map(&:to_s)
      assert_equal 3, keys.size
      keys.each do |key|
        refute_includes key, "user-secret"
        refute_includes key, "phone-secret"
        refute_includes key, "203.0.113.55"
        assert_match(/[0-9a-f]{64}/, key)
      end
    end

    test "uses the shared authentication throttle budget" do
      assert_equal Core::AuthThrottle::LIMIT, Core::InvitationThrottle::LIMIT
      assert_equal Core::AuthThrottle::WINDOW, Core::InvitationThrottle::WINDOW
    end

    private

    def throttle(actor_id:, contact_digest:, ip_address:)
      Core::InvitationThrottle.new(actor_id:, contact_digest:, ip_address:).call
    end

    def digest(value)
      Core::KeyedDigest.digest(namespace: "test/invitation-throttle", value:)
    end
  end
end
