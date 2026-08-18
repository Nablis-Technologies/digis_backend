# frozen_string_literal: true

require "digest"
require "test_helper"

module Ticketing
  class StreamSessionTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @event_date = @event.event_dates.create!(
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 2.hours,
        status: "scheduled"
      )
      @event_stream = Events::EventStream.create!(
        event_date: @event_date,
        provider: "youtube",
        provider_playback_id: "stream-#{SecureRandom.hex(4)}",
        access_protection: "public",
        status: "scheduled",
        live_from: @event_date.starts_at,
        live_until: @event_date.ends_at,
        replay_enabled: false,
        max_concurrent_devices: 1
      )
      @product = create_ticket_product
      @registration = create_registration
      @ticket = Ticketing::Ticket.create!(ticket_attributes)
    end

    test "Digis session token digest is globally unique" do
      first = Ticketing::StreamSession.create!(session_attributes)
      duplicate = first.dup
      duplicate.id = SecureRandom.uuid

      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "revoked session requires revocation time" do
      session = Ticketing::StreamSession.new(session_attributes(status: "revoked", revoked_at: nil))

      assert_not session.valid?
      assert session.errors.key?(:revoked_at)
    end

    test "database rejects a session whose ticket and stream belong to different events" do
      other_event = events_events(:draft_concert)
      other_date = other_event.event_dates.create!(
        starts_at: 3.days.from_now,
        ends_at: 3.days.from_now + 2.hours,
        status: "scheduled"
      )
      other_stream = Events::EventStream.create!(
        event_date: other_date,
        provider: "youtube",
        provider_playback_id: "other-stream-#{SecureRandom.hex(4)}",
        access_protection: "public",
        status: "scheduled",
        live_from: other_date.starts_at,
        live_until: other_date.ends_at,
        replay_enabled: false,
        max_concurrent_devices: 1
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::StreamSession.transaction(requires_new: true) do
          Ticketing::StreamSession.create!(session_attributes(event_stream: other_stream))
          Ticketing::StreamSession.connection.execute(
            "SET CONSTRAINTS trg_ticketing_stream_session_same_event IMMEDIATE"
          )
        end
      end
    end

    private

    def create_ticket_product
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Stream ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public",
          approval_mode: "automatic",
          date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      product.product_accesses.create!(
        event_date: @event_date,
        type: "stream",
        required_access_protection: "public"
      )
      product
    end

    def create_registration
      Ticketing::Registration.create!(
        event: @event,
        ticket_type: @product.ticket_type,
        user: @buyer,
        created_by: @buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "confirmed",
        submitted_at: Time.current,
        confirmed_at: Time.current
      )
    end

    def ticket_attributes
      {
        id: SecureRandom.uuid,
        event_id: @event.id,
        event_product_id: @product.id,
        registration_id: @registration.id,
        unit_number: 1,
        admissions_per_unit_snapshot: 1,
        owner_user_id: @buyer.id,
        current_acquisition_type: "free_registration",
        current_acquisition_product_value_minor: 0,
        current_acquisition_currency: "ETB",
        completed_resale_count: 0,
        credential_mode: "group",
        credential_version: 1,
        status: "active",
        issued_at: Time.current,
        lock_version: 0,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    def session_attributes(overrides = {})
      {
        ticket: @ticket,
        event_stream: @event_stream,
        user: @buyer,
        device_id: "ios:9f0f6af3",
        session_token_digest: Digest::SHA256.hexdigest(SecureRandom.hex(32)),
        status: "active",
        expires_at: 10.minutes.from_now,
        last_seen_at: nil,
        revoked_at: nil
      }.merge(overrides)
    end
  end
end
