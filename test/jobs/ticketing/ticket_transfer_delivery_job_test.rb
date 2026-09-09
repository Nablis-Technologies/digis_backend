# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketTransferDeliveryJobTest < ActiveJob::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @token = "transfer-delivery-secret"
      @transfer = @ticket.ticket_transfers.create!(
        from_user: @owner,
        to_user: @recipient,
        initiated_by: @owner,
        token: @token,
        token_digest: Ticketing::TicketTransfer.token_digest_for(token: @token),
        previous_version: @ticket.credential_version,
        status: "pending",
        expires_at: 1.day.from_now
      )
      @messages = []
      @previous_registry = Rails.application.config.x.messaging_provider_registry
      @previous_short_links = Rails.application.config.x.short_links.to_h
      @previous_public_app_url = Rails.application.config.x.public_app_url

      adapter = Object.new
      messages = @messages
      adapter.define_singleton_method(:deliver) { |**| Messaging::Providers::DeliveryResult.delivered(provider: "test") }
      adapter.define_singleton_method(:deliver_sms) do |**attributes|
        messages << [ :sms, attributes ]
        Messaging::Providers::DeliveryResult.delivered(provider: "test")
      end
      adapter.define_singleton_method(:deliver_email) do |**attributes|
        messages << [ :email, attributes ]
        Messaging::Providers::DeliveryResult.delivered(provider: "test")
      end
      registry = Messaging::Providers::Registry.new
      registry.register(channel: "sms", adapter:)
      registry.register(channel: "email", adapter:)
      Rails.application.config.x.messaging_provider_registry = registry
      Rails.application.config.x.short_links.enabled = true
      Rails.application.config.x.short_links.host = "localhost"
      Rails.application.config.x.short_links.protocol = "http"
      Rails.application.config.x.short_links.port = 3000
      Rails.application.config.x.public_app_url = "http://localhost:3000"
    end

    teardown do
      Rails.application.config.x.messaging_provider_registry = @previous_registry
      @previous_short_links.each { |key, value| Rails.application.config.x.short_links.public_send("#{key}=", value) }
      Rails.application.config.x.public_app_url = @previous_public_app_url
      Links::ShortLink.where(target_type: "ticket_transfer", target_id: @transfer.id).delete_all if @transfer&.persisted?
    end

    test "delivers a branded transfer link by SMS and email" do
      TicketTransferDeliveryJob.perform_now(@transfer.id)

      assert_equal %i[sms email], @messages.map(&:first)
      @messages.each do |_channel, attributes|
        assert_match(%r{http://localhost:3000/x-[a-z0-9]{6}\z}, attributes.fetch(:body))
      end
      assert_equal "ticketing-transfer-sms-#{@transfer.id}", @messages.first.last.fetch(:idempotency_key)
      assert_equal "ticketing-transfer-email-#{@transfer.id}", @messages.last.last.fetch(:idempotency_key)
    end

    test "does not deliver a terminal transfer" do
      @transfer.update!(status: "cancelled", cancelled_at: Time.current)

      assert_nothing_raised { TicketTransferDeliveryJob.perform_now(@transfer.id) }
      assert_empty @messages
    end
  end
end
