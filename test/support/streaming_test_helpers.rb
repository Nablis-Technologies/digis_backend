# frozen_string_literal: true

module StreamingTestHelpers
  def build_streaming_ticket(
    now: Time.current,
    stream_status: "live",
    access_protection: "public",
    replay_enabled: false,
    replay_available_until: nil,
    max_concurrent_devices: 1
  )
    @stream_event = events_events(:ready_listing)
    @stream_buyer = core_users(:attendee)
    live_from = now - 1.hour
    live_until = replay_enabled ? now - 10.minutes : now + 1.hour
    @stream_date = @stream_event.event_dates.create!(
      starts_at: live_from,
      ends_at: live_until,
      status: "scheduled"
    )
    @event_stream = Events::EventStream.create!(
      event_date: @stream_date,
      provider: "youtube",
      provider_playback_id: "stream-#{SecureRandom.hex(4)}",
      access_protection:,
      status: stream_status,
      live_from:,
      live_until:,
      replay_enabled:,
      replay_available_until: replay_available_until || (now + 1.hour if replay_enabled),
      max_concurrent_devices:
    )
    @stream_product = create_stream_product(access_protection:)
    @stream_registration = create_stream_registration
    @stream_ticket = Ticketing::Ticket.create!(stream_ticket_attributes)
    1.upto(@stream_ticket.admissions_per_unit_snapshot) do |position|
      @stream_ticket.admission_slots.create!(position:, assignment_status: "unassigned")
    end
    generation = @stream_ticket.credential_generations.create!(
      version: 1,
      mode: "group",
      status: "active",
      activated_at: now
    )
    @stream_ticket.update!(current_credential_generation: generation)
    @stream_credential = generation.credentials.create!(
      ticket: @stream_ticket,
      event: @stream_event,
      type: "package",
      status: "active",
      slot_positions: [ 1 ],
      entry_limit: 1,
      qr_token: "signed-#{SecureRandom.hex(8)}",
      lookup_code: "PNR#{SecureRandom.hex(3)}"[0, 8],
      issued_at: now
    )
  end

  private

  def create_stream_product(access_protection:)
    product = Catalog::Products::CreateDraft.call(
      event: @stream_event,
      actor: core_users(:super_admin),
      product_attributes: { name: "Stream product #{SecureRandom.hex(4)}", type: "ticket" },
      ticket_type_attributes: {
        audience: "public",
        approval_mode: "automatic",
        date_selection: "fixed",
        admissions_per_unit: 1
      },
      inventory_configuration: { mode: "unlimited" }
    ).value
    product.product_accesses.create!(
      event_date: @stream_date,
      type: "stream",
      required_access_protection: access_protection
    )
    product
  end

  def create_stream_registration
    Ticketing::Registration.create!(
      event: @stream_event,
      ticket_type: @stream_product.ticket_type,
      user: @stream_buyer,
      created_by: @stream_buyer,
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

  def stream_ticket_attributes
    {
      id: SecureRandom.uuid,
      event_id: @stream_event.id,
      event_product_id: @stream_product.id,
      registration_id: @stream_registration.id,
      unit_number: 1,
      admissions_per_unit_snapshot: 1,
      owner_user_id: @stream_buyer.id,
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

  def create_stream_session(device_id: "ios:9f0f6af3", expires_at: 10.minutes.from_now)
    Ticketing::StreamSession.create!(
      ticket: @stream_ticket,
      event_stream: @event_stream,
      user: @stream_buyer,
      device_id:,
      session_token_digest: Core::KeyedDigest.digest(
        namespace: "streaming-session",
        value: SecureRandom.urlsafe_base64(32)
      ),
      status: "active",
      expires_at:
    )
  end
end
