# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PublicRsvpsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update!(status: "published")
      @ticket_type = create_rsvp_ticket_type
      @delivered_codes = []
      @previous_sender = Rails.application.config.x.phone_verification_sender
      Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
        @delivered_codes << { phone:, code:, challenge_id: challenge.id }
      end
    end

    teardown do
      Rails.application.config.x.phone_verification_sender = @previous_sender
    end

    test "missing RSVP idempotency key returns bad request" do
      post "/public/events/#{@event.slug}/rsvp",
           params: { rsvp: { ticket_type_id: @ticket_type.id } },
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "missing guest RSVP phone names the missing parameter" do
      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: { rsvp: { ticket_type_id: @ticket_type.id } },
           headers: { "Idempotency-Key" => "public-rsvp-otp-missing-phone" },
           as: :json

      assert_response :bad_request
      assert_equal "invalid_request", response.parsed_body.fetch("code")
      assert_equal "Required parameter 'phone' is missing", response.parsed_body.fetch("error")
    end

    test "guest RSVP OTP returns challenge metadata and no code" do
      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: {
             rsvp: { ticket_type_id: @ticket_type.id, phone: "+251911000071" }
           },
           headers: { "Idempotency-Key" => "public-rsvp-otp-1" },
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "pending", data.fetch("status")
      assert data.fetch("challenge_id").present?
      refute data.key?("code")
      assert_equal 1, @delivered_codes.length
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    test "authenticated automatic RSVP returns an attendee-safe ticket" do
      post "/public/events/#{@event.slug}/rsvp",
           params: { rsvp: { ticket_type_id: @ticket_type.id, package_quantity: 1 } },
           headers: user_headers.merge("Idempotency-Key" => "public-rsvp-auth-1"),
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "confirmed", data.dig("next_action", "type")
      ticket = data.fetch("tickets").sole
      assert_equal "active", ticket.fetch("status")
      assert ticket.fetch("credentials").present?
      refute ticket.key?("owner_user_id")
      refute ticket.key?("commercial_signature")
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    test "guest RSVP verifies an OTP before creating the ticket" do
      phone = "+251911000072"
      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: { rsvp: { ticket_type_id: @ticket_type.id, phone: } },
           headers: { "Idempotency-Key" => "public-rsvp-otp-2" },
           as: :json
      assert_response :created
      challenge_id = response.parsed_body.dig("data", "challenge_id")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @delivered_codes.last.fetch(:code) },
           headers: { "Idempotency-Key" => "public-rsvp-verify-1" },
           as: :json
      assert_response :success
      verification_token = response.parsed_body.dig("data", "verification_token")

      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: {
               ticket_type_id: @ticket_type.id,
               phone:,
               verification_token:,
               package_quantity: 1
             }
           },
           headers: { "Idempotency-Key" => "public-rsvp-guest-1" },
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "confirmed", data.dig("next_action", "type")
      assert_equal 1, data.fetch("tickets").length
      assert Core::User.where(phone: [ "251911000072", "+251911000072" ]).exists?
    end

    test "guest access-code RSVP checks proof before OTP and registration" do
      gated_type = create_rsvp_ticket_type(audience: "access_code")
      raw_code = "RSVP-CODE-#{SecureRandom.hex(4)}"
      access_code = create_access_code(gated_type, raw_code)
      phone = "+251911000076"

      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: { rsvp: { ticket_type_id: gated_type.id, phone: } },
           headers: { "Idempotency-Key" => "public-rsvp-gated-code-missing" },
           as: :json

      assert_response :unprocessable_entity
      assert_empty @delivered_codes
      assert_empty Core::PhoneVerificationChallenge.where(purpose: "guest_rsvp")

      verification_token = request_guest_rsvp_verification(
        ticket_type: gated_type,
        phone:,
        proof: { access_code: raw_code },
        suffix: "gated-code"
      )

      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: {
               ticket_type_id: gated_type.id, phone:, verification_token:, package_quantity: 1
             }
           },
           headers: { "Idempotency-Key" => "public-rsvp-gated-code-submit-missing" },
           as: :json

      assert_response :unprocessable_entity
      assert_empty Registration.where(ticket_type: gated_type)

      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: {
               ticket_type_id: gated_type.id, phone:, verification_token:,
               access_code: raw_code, package_quantity: 1
             }
           },
           headers: { "Idempotency-Key" => "public-rsvp-gated-code-submit-valid" },
           as: :json

      assert_response :created
      assert_equal "confirmed", response.parsed_body.dig("data", "next_action", "type")
      registration = Registration.find_by!(ticket_type: gated_type)
      assert_equal 1, access_code.reload.used_count
      assert_equal access_code.id, registration.access_code_id
    end

    test "guest invitation RSVP checks proof before OTP and registration" do
      gated_type = create_rsvp_ticket_type(audience: "invitation")
      invitation_token = SecureRandom.hex(24)
      invitation = create_invitation(gated_type, invitation_token)
      phone = "+251911000077"

      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: { rsvp: { ticket_type_id: gated_type.id, phone: } },
           headers: { "Idempotency-Key" => "public-rsvp-gated-invitation-missing" },
           as: :json

      assert_response :unprocessable_entity
      assert_empty @delivered_codes
      assert_empty Core::PhoneVerificationChallenge.where(purpose: "guest_rsvp")

      verification_token = request_guest_rsvp_verification(
        ticket_type: gated_type,
        phone:,
        proof: { invitation_token: },
        suffix: "gated-invitation"
      )

      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: {
               ticket_type_id: gated_type.id, phone:, verification_token:, package_quantity: 1
             }
           },
           headers: { "Idempotency-Key" => "public-rsvp-gated-invitation-submit-missing" },
           as: :json

      assert_response :unprocessable_entity
      assert_empty Registration.where(ticket_type: gated_type)

      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: {
               ticket_type_id: gated_type.id, phone:, verification_token:,
               invitation_token:, package_quantity: 1
             }
           },
           headers: { "Idempotency-Key" => "public-rsvp-gated-invitation-submit-valid" },
           as: :json

      assert_response :created
      assert_equal "confirmed", response.parsed_body.dig("data", "next_action", "type")
      registration = Registration.find_by!(ticket_type: gated_type)
      assert_equal invitation.id, registration.invitation_id
      assert_equal "accepted", invitation.reload.status
      assert_equal registration.user_id, invitation.invited_user_id
    end

    test "bound invitation rejects a mismatched guest phone before creating an OTP identity" do
      gated_type = create_rsvp_ticket_type(audience: "invitation")
      invitation_token = SecureRandom.hex(24)
      invitation = create_invitation(gated_type, invitation_token)
      bound_phone = "+251911000078"
      bound_identity = Core::PhoneIdentity::ResolveOrCreate.call(
        phone: bound_phone, actor: nil, allow_actor_mismatch: true
      )
      assert_predicate bound_identity, :success?, bound_identity.error&.message
      invitation.update!(invited_user: bound_identity.value.user)
      users_before_request = Core::User.count
      other_phone = "+251911000079"

      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: {
             rsvp: { ticket_type_id: gated_type.id, phone: other_phone, invitation_token: }
           },
           headers: { "Idempotency-Key" => "public-rsvp-bound-invite-mismatch" },
           as: :json

      assert_response :unprocessable_entity
      assert_empty @delivered_codes
      assert_empty Core::PhoneVerificationChallenge.where(purpose: "guest_rsvp")
      assert_equal users_before_request, Core::User.count

      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: {
             rsvp: { ticket_type_id: gated_type.id, phone: bound_phone, invitation_token: }
           },
           headers: { "Idempotency-Key" => "public-rsvp-bound-invite-same-claimant" },
           as: :json

      assert_response :created
      assert_equal 1, @delivered_codes.length
      assert_equal "pending", invitation.reload.status
    end

    test "authenticated RSVP accepts a valid access code" do
      gated_type = create_rsvp_ticket_type(audience: "access_code")
      raw_code = "RSVP-AUTH-CODE-#{SecureRandom.hex(4)}"
      create_access_code(gated_type, raw_code)

      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: { ticket_type_id: gated_type.id, access_code: raw_code, package_quantity: 1 }
           },
           headers: user_headers.merge("Idempotency-Key" => "public-rsvp-auth-gated-code"),
           as: :json

      assert_response :created
      assert_equal "confirmed", response.parsed_body.dig("data", "next_action", "type")
      assert_equal 1, Registration.where(ticket_type: gated_type).count
    end

    test "manual RSVP returns an approval action without a ticket" do
      manual_type = create_rsvp_ticket_type(approval_mode: "manual")

      post "/public/events/#{@event.slug}/rsvp",
           params: { rsvp: { ticket_type_id: manual_type.id, package_quantity: 1 } },
           headers: user_headers.merge("Idempotency-Key" => "public-rsvp-manual-1"),
           as: :json

      assert_response :accepted
      data = response.parsed_body.fetch("data")
      assert_equal "awaiting_approval", data.dig("next_action", "type")
      assert_empty data.fetch("tickets")
    end

    test "replaying an automatic RSVP returns the same ticket without duplicates" do
      headers = user_headers.merge("Idempotency-Key" => "public-rsvp-replay-1")
      params = { rsvp: { ticket_type_id: @ticket_type.id, package_quantity: 1 } }

      post "/public/events/#{@event.slug}/rsvp", params:, headers:, as: :json
      assert_response :created
      first = response.parsed_body.fetch("data")
      registration_id = first.dig("registration", "id")
      ticket_id = first.fetch("tickets").sole.fetch("id")

      post "/public/events/#{@event.slug}/rsvp", params:, headers:, as: :json
      assert_response :success
      replay = response.parsed_body.fetch("data")
      assert_equal registration_id, replay.dig("registration", "id")
      assert_equal ticket_id, replay.fetch("tickets").sole.fetch("id")
      assert_equal 1, Registration.where(id: registration_id).count
      assert_equal 1, Ticketing::Ticket.where(registration_id:).count
    end

    test "paid products stay on the checkout flow" do
      paid_type = create_rsvp_ticket_type(amount_minor: 100)

      post "/public/events/#{@event.slug}/rsvp",
           params: { rsvp: { ticket_type_id: paid_type.id } },
           headers: user_headers.merge("Idempotency-Key" => "public-rsvp-paid-1"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "rsvp_paid_product_requires_checkout", response.parsed_body.fetch("code")
      assert_empty Registration.where(ticket_type: paid_type)
    end

    test "an invalid bearer token cannot downgrade to guest mode" do
      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: { ticket_type_id: @ticket_type.id, phone: "+251911000073" }
           },
           headers: {
             "Authorization" => "Bearer invalid-token",
             "Idempotency-Key" => "public-rsvp-invalid-bearer"
           },
           as: :json

      assert_response :unauthorized
      assert_equal "authentication_required", response.parsed_body.fetch("code")
    end

    test "guest can reuse the RSVP proof to claim the account" do
      phone = "+251911000074"
      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: { rsvp: { ticket_type_id: @ticket_type.id, phone: } },
           headers: { "Idempotency-Key" => "public-rsvp-otp-claim" },
           as: :json
      challenge_id = response.parsed_body.dig("data", "challenge_id")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @delivered_codes.last.fetch(:code) },
           headers: { "Idempotency-Key" => "public-rsvp-verify-claim" },
           as: :json
      verification_token = response.parsed_body.dig("data", "verification_token")

      post "/public/events/#{@event.slug}/rsvp",
           params: {
             rsvp: { ticket_type_id: @ticket_type.id, phone:, verification_token: }
           },
           headers: { "Idempotency-Key" => "public-rsvp-guest-claim" },
           as: :json
      assert_response :created
      registration_id = response.parsed_body.dig("data", "registration", "id")

      post "/registrations/#{registration_id}/claim_guest",
           params: {
             phone:,
             verification_token:,
             password: "password123",
             password_confirmation: "password123"
           },
           headers: { "Idempotency-Key" => "public-rsvp-claim-account" },
           as: :json

      assert_response :success
      assert response.parsed_body.dig("data", "access_token").present?
      assert response.parsed_body.dig("data", "refresh_token").present?
    end

    private

    def create_rsvp_ticket_type(approval_mode: "automatic", amount_minor: 0, audience: "public")
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "RSVP #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience:, approval_mode:, date_selection: "fixed", admissions_per_unit: 1
        },
        price_attributes: { type: "base", currency: "ETB", amount_minor:, active_from: 1.minute.ago },
        inventory_configuration: { mode: "unlimited" }
      )
      assert_predicate product, :success?, product.error&.message
      event_date = @event.event_dates.create!(
        name: "RSVP date #{SecureRandom.hex(3)}",
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 2.hours,
        status: "scheduled"
      )
      product.value.product_accesses.create!(event_date:, type: "venue")
      activated = Catalog::Products::Activate.call(product: product.value, actor: core_users(:super_admin))
      assert_predicate activated, :success?, activated.error&.message
      activated.value.ticket_type
    end

    def request_guest_rsvp_verification(ticket_type:, phone:, proof:, suffix:)
      post "/public/events/#{@event.slug}/rsvp/request_otp",
           params: { rsvp: { ticket_type_id: ticket_type.id, phone: }.merge(proof) },
           headers: { "Idempotency-Key" => "public-rsvp-otp-#{suffix}" },
           as: :json

      assert_response :created
      challenge_id = response.parsed_body.dig("data", "challenge_id")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @delivered_codes.last.fetch(:code) },
           headers: { "Idempotency-Key" => "public-rsvp-verify-#{suffix}" },
           as: :json

      assert_response :success
      response.parsed_body.dig("data", "verification_token")
    end

    def create_access_code(ticket_type, raw_code)
      Ticketing::AccessCode.create!(
        ticket_type:,
        code_digest: Ticketing::AccessCode.code_digest_for(
          event_id: @event.id, code: raw_code
        ),
        max_uses: 5,
        used_count: 0,
        max_quantity_per_use: 1,
        active: true
      )
    end

    def create_invitation(ticket_type, raw_token)
      event_id = @event.id
      email = "rsvp-#{SecureRandom.hex(4)}@example.com"
      Ticketing::Invitation.create!(
        ticket_type:,
        created_by: core_users(:super_admin),
        email:,
        contact_digest: Ticketing::Invitation.contact_digest_for(event_id:, contact: email),
        token: raw_token,
        token_digest: Ticketing::Invitation.token_digest_for(event_id:, token: raw_token),
        allowed_quantity: 1,
        status: "pending"
      )
    end
  end
end
