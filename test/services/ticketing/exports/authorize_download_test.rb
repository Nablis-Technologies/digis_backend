# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Exports
    class AuthorizeDownloadTest < ActiveSupport::TestCase
      include Ticketing::AttendeeExportTestHelpers

      setup do
        @actor = core_users(:super_admin)
        @event = events_events(:ready_listing)
        @export = create_export(event: @event, actor: @actor, overrides: { status: "ready" })
        @export.file.attach(io: StringIO.new("private csv"), filename: "export.csv", content_type: "text/csv")
        @session = Core::RefreshToken.generate(@actor, ActionDispatch::TestRequest.create)
        ActiveStorage::Current.url_options = { host: "example.com" }
      end

      teardown do
        @session&.delete
        ActiveStorage::Current.url_options = nil
      end

      test "consumes a download proof, audits authorization, and returns a capped private URL" do
        proof = issue_proof

        result = AuthorizeDownload.call(
          attendee_export_id: @export.id,
          actor: @actor,
          session_jti: @session.jti,
          raw_proof: proof
        )

        assert_predicate result, :success?, result.error&.message
        assert_kind_of String, result.value.fetch(:url)
        assert_operator result.value.fetch(:expires_at), :>, Time.current
        assert_operator result.value.fetch(:expires_at), :<=, 2.minutes.from_now
        assert_equal Time.current.to_date, @export.reload.last_download_authorized_at.to_date
        assert Core::AuditLog.exists?(
          action: "ticketing.attendee_export.download_authorized",
          auditable_type: @export.class.name,
          auditable_id: @export.id
        )
        assert_predicate Core::ReauthenticationProof.where(token_digest: digest(proof)).sole.consumed_at, :present?
      end

      test "rejects an export that is not ready before consuming a download proof" do
        @export.reload.update!(status: "pending", processing_started_at: nil, ready_at: nil)
        proof = issue_proof

        result = AuthorizeDownload.call(
          attendee_export_id: @export.id,
          actor: @actor,
          session_jti: @session.jti,
          raw_proof: proof
        )

        assert_predicate result, :failure?
        assert_equal "export_not_ready", result.error.code
        assert_nil @export.reload.last_download_authorized_at
        assert_nil Core::ReauthenticationProof.where(token_digest: digest(proof)).sole.consumed_at
      end

      test "rejects a ready export after it expires" do
        @export.reload.update!(data_cutoff_at: 2.days.ago, expires_at: 1.minute.ago)
        proof = issue_proof

        result = AuthorizeDownload.call(
          attendee_export_id: @export.id,
          actor: @actor,
          session_jti: @session.jti,
          raw_proof: proof
        )

        assert_predicate result, :failure?
        assert_equal "export_expired", result.error.code
        assert_nil Core::ReauthenticationProof.where(token_digest: digest(proof)).sole.consumed_at
      end

      private

      def issue_proof
        Core::Reauthentication::Issue.call(
          user: @actor,
          session_jti: @session.jti,
          purpose: "attendee_export_download",
          password: "password123"
        ).value
      end

      def digest(proof)
        Core::KeyedDigest.digest(
          namespace: "core/reauthentication/proof/attendee_export_download",
          value: proof
        )
      end
    end
  end
end
