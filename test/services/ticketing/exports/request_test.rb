# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Exports
    class RequestTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @other_event = events_events(:draft_concert)
        @actor = core_users(:super_admin)
        @session = Core::RefreshToken.generate(@actor, ActionDispatch::TestRequest.create)
      end

      teardown do
        @session&.delete
      end

      test "creates a pending export, consumes one proof, audits, and publishes dispatch evidence" do
        raw_proof = issue_proof

        result = request_export(raw_proof:)

        assert_predicate result, :success?, result.error&.message
        export = result.value
        assert_equal @event.id, export.event_id
        assert_equal @actor.id, export.requested_by_id
        assert_equal "pending", export.status
        assert_not_nil proof_record(raw_proof).reload.consumed_at

        audit = Core::AuditLog.find_by!(
          action: "ticketing.attendee_export.requested",
          auditable_type: export.class.name,
          auditable_id: export.id
        )
        assert_equal @actor.id, audit.actor_id
        assert_equal 1, Core::OutboxEvent.where(
          event_type: "ticketing.attendee_export.requested",
          aggregate_id: export.id
        ).count
      end

      test "exact replay returns the original export before reading or consuming a proof" do
        raw_proof = issue_proof
        first = request_export(raw_proof:)
        export = first.value
        proof = proof_record(raw_proof).reload
        audit_count = Core::AuditLog.where(action: "ticketing.attendee_export.requested").count
        outbox_count = Core::OutboxEvent.where(event_type: "ticketing.attendee_export.requested").count

        Core::Reauthentication::Consume.expects(:call).never
        replay = request_export(raw_proof: nil)

        assert_predicate replay, :success?, replay.error&.message
        assert_equal export.id, replay.value.id
        assert_equal proof.consumed_at, proof_record(raw_proof).reload.consumed_at
        assert_equal audit_count, Core::AuditLog.where(action: "ticketing.attendee_export.requested").count
        assert_equal outbox_count, Core::OutboxEvent.where(event_type: "ticketing.attendee_export.requested").count
      end

      test "exact replay ignores consumed, malformed, and expired proof inputs" do
        raw_proof = issue_proof
        first = request_export(raw_proof:)
        assert_predicate first, :success?, first.error&.message
        expired_proof = issue_proof
        audit_count = Core::AuditLog.where(action: "ticketing.attendee_export.requested").count
        outbox_count = Core::OutboxEvent.where(event_type: "ticketing.attendee_export.requested").count

        travel_to 6.minutes.from_now do
          replay_checks = lambda do
            [ raw_proof, "malformed-proof", expired_proof ].each do |proof|
              replay = request_export(raw_proof: proof)

              assert_predicate replay, :success?, replay.error&.message
              assert_equal first.value.id, replay.value.id
            end
          end
          defined?(Prosopite) ? Prosopite.pause(&replay_checks) : replay_checks.call
        end

        assert_equal audit_count, Core::AuditLog.where(action: "ticketing.attendee_export.requested").count
        assert_equal outbox_count, Core::OutboxEvent.where(event_type: "ticketing.attendee_export.requested").count
      end

      test "rechecks current field authorization before accepting an exact replay" do
        raw_proof = issue_proof
        first = request_export(raw_proof:)
        assert_predicate first, :success?, first.error&.message
        @actor.stubs(:has_permission?).returns(false)

        replay = request_export(raw_proof: nil)

        assert_predicate replay, :failure?
        assert_equal "not_authorized", replay.error.code
      end

      test "exact replay is idempotent and does not duplicate export or outbox effects" do
        raw_proof = issue_proof
        subject = lambda do
          request_export(raw_proof:, idempotency_key: "export-idempotent-key")
        end

        assert_idempotent(
          subject,
          counter: -> { Ticketing::AttendeeExport.count }
        )
        assert_equal 1, Core::OutboxEvent.where(event_type: "ticketing.attendee_export.requested").count
      end

      test "exact replay does not duplicate its audit row" do
        raw_proof = issue_proof
        export_id = nil
        subject = lambda do
          result = request_export(raw_proof:, idempotency_key: "audit-idempotent-key")
          export_id ||= result.value&.id
          result
        end

        assert_audit_idempotent(
          subject,
          action: "ticketing.attendee_export.requested",
          auditable_type: "Ticketing::AttendeeExport",
          auditable_id: -> { export_id }
        )
      end

      test "requires a proof only for a genuinely new request" do
        result = request_export(raw_proof: nil)

        assert_predicate result, :failure?
        assert_equal "invalid_reauthentication_proof", result.error.code
        assert_equal 0, Ticketing::AttendeeExport.count
        assert_empty Core::AuditLog.where(action: "ticketing.attendee_export.requested")
        assert_empty Core::OutboxEvent.where(event_type: "ticketing.attendee_export.requested")
      end

      test "treats omitted filters as an empty filter set" do
        result = request_export(raw_proof: issue_proof, filters: nil)

        assert_predicate result, :success?, result.error&.message
        assert_equal({}, result.value.filters)
      end

      test "returns an idempotency conflict for a different request under the same key" do
        raw_proof = issue_proof
        first = request_export(raw_proof:)
        assert_predicate first, :success?, first.error&.message

        second = request_export(raw_proof: issue_proof, field_keys: [ "registration_status" ])

        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 409, second.error.status
        assert_equal 1, Ticketing::AttendeeExport.count
      end

      test "treats selector order as part of the idempotent request" do
        first = request_export(
          raw_proof: issue_proof,
          field_keys: [ "registration_id", "registration_status" ]
        )
        assert_predicate first, :success?, first.error&.message

        second = request_export(
          raw_proof: issue_proof,
          field_keys: [ "registration_status", "registration_id" ]
        )

        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
      end

      test "replays through a retained historical export digest key" do
        Core::AttendeeExportDigest.stubs(:key_ring).returns({ "v1" => "old-key", "v2" => "new-key" })
        Core::AttendeeExportDigest.stubs(:current_version).returns("v2")
        first = request_export(raw_proof: issue_proof)
        assert_predicate first, :success?, first.error&.message
        assert_equal "v2", first.value.digest_key_version

        Core::AttendeeExportDigest.stubs(:current_version).returns("v1")
        replay = request_export(raw_proof: nil)

        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
      end

      test "rechecks current authorization before consuming a new request proof" do
        actor = core_users(:core_admin)
        session = Core::RefreshToken.generate(actor, ActionDispatch::TestRequest.create)
        raw_proof = issue_proof(actor:, session_jti: session.jti)

        result = request_export(actor:, session_jti: session.jti, raw_proof:)

        assert_predicate result, :failure?
        assert_equal "not_authorized", result.error.code
        assert_nil proof_record(raw_proof, actor:).reload.consumed_at
      ensure
        session&.delete
      end

      test "rejects filters belonging to another event before proof consumption" do
        foreign_ticket_type = create_ticket_type(@other_event, "Foreign export ticket")
        raw_proof = issue_proof

        result = request_export(
          raw_proof:,
          filters: { "ticket_type_ids" => [ foreign_ticket_type.id ] }
        )

        assert_predicate result, :failure?
        assert_equal "invalid_filters", result.error.code
        assert_nil proof_record(raw_proof).reload.consumed_at
      end

      test "rejects oversized selectors before field resolution or proof consumption" do
        raw_proof = issue_proof
        Ticketing::Exports::FieldRegistry.expects(:resolve).never

        result = request_export(
          raw_proof:,
          field_keys: Array.new(101) { |index| "registration_#{index}" }
        )

        assert_predicate result, :failure?
        assert_equal "invalid_field_keys", result.error.code
        assert_nil proof_record(raw_proof).reload.consumed_at
      end

      test "rejects oversized filters before field resolution or proof consumption" do
        raw_proof = issue_proof
        Ticketing::Exports::FieldRegistry.expects(:resolve).never

        result = request_export(
          raw_proof:,
          filters: { "ticket_type_ids" => Array.new(101) { SecureRandom.uuid } }
        )

        assert_predicate result, :failure?
        assert_equal "invalid_filters", result.error.code
        assert_nil proof_record(raw_proof).reload.consumed_at
      end

      private

      def request_export(
        actor: @actor,
        session_jti: @session.jti,
        raw_proof:,
        event: @event,
        field_keys: [ "registration_id" ],
        filters: {},
        row_mode: "registration",
        reason_code: "event_operations",
        idempotency_key: "export-request-key"
      )
        Ticketing::Exports::Request.call(
          actor:,
          event:,
          session_jti:,
          raw_proof:,
          idempotency_key:,
          row_mode:,
          field_keys:,
          filters:,
          reason_code:
        )
      end

      def issue_proof(actor: @actor, session_jti: @session.jti)
        result = Core::Reauthentication::Issue.call(
          user: actor,
          session_jti:,
          purpose: "attendee_export_request",
          password: "password123"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def proof_record(raw_proof, actor: @actor)
        digest = Core::KeyedDigest.digest(
          namespace: "core/reauthentication/proof/attendee_export_request",
          value: raw_proof
        )
        Core::ReauthenticationProof.find_by!(user_id: actor.id, token_digest: digest)
      end

      def create_ticket_type(event, name)
        Catalog::Products::CreateDraft.call(
          event:,
          actor: @actor,
          product_attributes: { name:, type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
      end
    end
  end
end
