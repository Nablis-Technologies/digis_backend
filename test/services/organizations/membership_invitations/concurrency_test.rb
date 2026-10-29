# frozen_string_literal: true

require "test_helper"

module Organizations
  module MembershipInvitations
    class ConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
        @organization = organizations_organizations(:two)
        @owner = core_users(:core_admin)
        @invitee = core_users(:attendee)
        @membership_ids_before = @organization.memberships.where(user: @invitee).pluck(:id)
        @contact = "+251911999931"
      end

      teardown do
        invitation_ids = @invitation_ids || []
        Core::AuditLog.where(auditable_type: MembershipInvitation.name, auditable_id: invitation_ids).delete_all
        Core::OutboxEvent.where(aggregate_id: invitation_ids).delete_all
        MembershipInvitation.where(id: invitation_ids).delete_all

        added_membership_ids = @organization.memberships.where(user: @invitee).where.not(id: @membership_ids_before).pluck(:id)
        Core::AuditLog.where(auditable_type: Organizations::Membership.name, auditable_id: added_membership_ids).delete_all
        Organizations::Membership.where(id: added_membership_ids).delete_all
      end

      test "concurrent create requests for one scoped phone yield one pending invitation" do
        results = concurrently do |index|
          MembershipInvitations::Create.call(
            organization: @organization,
            actor: @owner,
            phone: @contact,
            role: "staff",
            idempotency_key: "org-concurrent-create-#{index}",
            ip_address: "203.0.113.#{100 + index}"
          )
        end

        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count { |result| result.failure? && result.error.code == "invitation_already_pending" }
        assert_equal 1, MembershipInvitation.pending.where(organization: @organization).count
        invitation = results.find(&:success?).value.record
        @invitation_ids = [ invitation.id ]
        assert_equal 1, Core::OutboxEvent.where(
          aggregate_id: invitation.id,
          event_type: "organizations.membership_invitation.delivery_requested"
        ).count
      end

      test "concurrent claims of one capability create exactly one membership and acceptance audit" do
        created = MembershipInvitations::Create.call(
          organization: @organization,
          actor: @owner,
          phone: @invitee.phone,
          role: "staff",
          idempotency_key: "org-concurrent-claim-create-#{SecureRandom.hex(5)}",
          ip_address: "203.0.113.110"
        )
        assert_predicate created, :success?, created.error&.message
        invitation = created.value.record
        @invitation_ids = [ invitation.id ]

        results = concurrently do |index|
          MembershipInvitations::Claim.call(
            token: created.value.token,
            actor: @invitee,
            idempotency_key: "org-concurrent-claim-#{index}",
            ip_address: "203.0.113.#{111 + index}"
          )
        end

        assert_equal 1, results.count(&:success?)
        assert_equal "accepted", invitation.reload.status
        assert_equal 1, @organization.memberships.where(user: @invitee).count
        assert_equal 1, Core::AuditLog.where(
          auditable: invitation,
          action: "organizations.membership_invitation.accepted"
        ).count
      end

      private

      def concurrently(&operation)
        ready = Queue.new
        start = Queue.new
        results = Queue.new
        errors = Queue.new
        threads = 2.times.map do |index|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ready << true
              start.pop
              results << operation.call(index)
            end
          rescue StandardError => error
            errors << error
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        threads.each(&:join)
        raise errors.pop unless errors.empty?

        2.times.map { results.pop }
      end
    end
  end
end
