# frozen_string_literal: true

require "test_helper"

module Ticketing
  class GuestTicketDeliveryJobTest < ActiveJob::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @shadow = Core::User.create!(phone: "+251911000081")
      Ticketing::Ticket.where(id: @ticket.id).update_all(owner_user_id: @shadow.id)
      @messages = []
      @previous_registry = Rails.application.config.x.messaging_provider_registry
      @short_link_config = Rails.application.config.x.short_links
      @previous_short_links = {
        enabled: @short_link_config.enabled,
        host: @short_link_config.host,
        protocol: @short_link_config.protocol,
        port: @short_link_config.port,
        public_app_url: Rails.application.config.x.public_app_url
      }
      adapter = Object.new
      messages = @messages
      adapter.define_singleton_method(:deliver_sms) do |**attributes|
        messages << attributes
        Messaging::Providers::DeliveryResult.delivered(provider: "test")
      end
      adapter.define_singleton_method(:deliver) { |**| Messaging::Providers::DeliveryResult.delivered(provider: "test") }
      @registry = Messaging::Providers::Registry.new
      @registry.register(channel: "sms", adapter:)
      Rails.application.config.x.messaging_provider_registry = @registry
    end

    teardown do
      Rails.application.config.x.messaging_provider_registry = @previous_registry
      @short_link_config.enabled = @previous_short_links.fetch(:enabled)
      @short_link_config.host = @previous_short_links.fetch(:host)
      @short_link_config.protocol = @previous_short_links.fetch(:protocol)
      @short_link_config.port = @previous_short_links.fetch(:port)
      Rails.application.config.x.public_app_url = @previous_short_links.fetch(:public_app_url)
    end

    test "sends a signed public ticket link after issuance" do
      @short_link_config.enabled = false
      GuestTicketDeliveryJob.perform_now(@ticket.id)

      assert_equal 1, @messages.length
      message = @messages.first
      assert_equal @shadow.phone, message.fetch(:phone)
      assert_includes message.fetch(:body), "/public/tickets/#{@ticket.id}?view_token="
      assert_equal "ticketing-guest-ticket-sms-#{@ticket.id}-v1", message.fetch(:idempotency_key)
    end

    test "sends a compact branded ticket link when branded links are enabled" do
      @short_link_config.enabled = true
      @short_link_config.host = "localhost"
      @short_link_config.protocol = "http"
      @short_link_config.port = 3000

      GuestTicketDeliveryJob.perform_now(@ticket.id)

      assert_equal 1, @messages.length
      assert_match(%r{http://localhost:3000/t-[a-z0-9]{6}\b}, @messages.first.fetch(:body))
      assert_equal 1, Links::ShortLink.where(
        canonical: true, target_type: "ticket", target_id: @ticket.id
      ).count
    end

    test "does not send to a claimed user" do
      @shadow.update!(verified_at: Time.current, password: "password123", password_confirmation: "password123")

      GuestTicketDeliveryJob.perform_now(@ticket.id)

      assert_empty @messages
    end
  end
end
