# frozen_string_literal: true

require "test_helper"

module Ticketing
  class AttendeeExportTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @other_event = events_events(:draft_concert)
      @requester = core_users(:super_admin)
    end

    test "uses UUID primary keys and requires event and requester foreign keys" do
      assert_equal :uuid, AttendeeExport.type_for_attribute("id").type

      assert_predicate build_export, :valid?
      assert_not build_export(event: nil).valid?
      assert_not build_export(requested_by: nil).valid?

      foreign_keys = AttendeeExport.connection.foreign_keys(AttendeeExport.table_name)
      assert_includes foreign_keys.map(&:column), "event_id"
      assert_includes foreign_keys.map(&:column), "requested_by_id"
    end

    test "database schema defines UUIDv7 defaults, required evidence columns, and lock state" do
      columns = schema_columns

      assert_equal "uuid", columns.fetch("id").fetch("udt_name")
      assert_match(/uuidv7\(\)/, columns.fetch("id").fetch("column_default"))

      required_columns = %w[
        id event_id requested_by_id status row_mode format_version field_set_digest
        filter_digest reason_code data_cutoff_at expires_at idempotency_key_digest
        request_fingerprint digest_key_version attempt_count lock_version created_at updated_at
      ]
      required_columns.each do |column|
        assert_equal "NO", columns.fetch(column).fetch("is_nullable"), "#{column} must be required"
      end
      assert_equal "YES", columns.fetch("field_keys").fetch("is_nullable")
      assert_equal "YES", columns.fetch("filters").fetch("is_nullable")

      assert_match(/0/, columns.fetch("lock_version").fetch("column_default"))

      fk_targets = foreign_key_targets
      assert_equal [ "events_events", "id" ], fk_targets.fetch("event_id")
      assert_equal [ "core_users", "id" ], fk_targets.fetch("requested_by_id")
    end

    test "database schema indexes event, actor, status, due expiry, and unique idempotency lookup" do
      definitions = index_definitions

      assert definitions.any? { |definition| definition.include?("(event_id)") }
      assert definitions.any? { |definition| definition.include?("(requested_by_id)") }
      assert definitions.any? { |definition| definition.include?("status") }
      assert definitions.any? { |definition| definition.include?("expires_at") }
      assert definitions.any? do |definition|
        definition.match?(/CREATE UNIQUE INDEX/i) && definition.include?("idempotency_key_digest")
      end
    end

    test "database checks enforce allowlists, digest shapes, JSON cardinality, bounds, and tombstones" do
      checks = constraint_definitions
      joined_checks = checks.join("\n")

      %w[pending processing ready failed expiring expired].each do |status|
        assert_includes joined_checks, "'#{status}'"
      end
      %w[registration admission].each { |mode| assert_includes joined_checks, "'#{mode}'" }
      assert_includes joined_checks, "'csv_v1'"
      %w[
        event_operations attendee_communication dietary_accommodation
        accessibility_accommodation customer_support legal_compliance
      ].each { |reason| assert_includes joined_checks, "'#{reason}'" }

      assert_operator checks.count { |definition| definition.include?("[0-9a-f]{64}") }, :>=, 4
      assert checks.any? { |definition| definition.include?("jsonb_typeof(field_keys)") && definition.include?("array") }
      assert checks.any? { |definition| definition.include?("jsonb_typeof(filters)") && definition.include?("object") }
      assert checks.any? { |definition| definition.include?("jsonb_array_length(field_keys)") && definition.include?("100") }
      assert checks.any? { |definition| definition.include?("attempt_count") && definition.include?("3") }
      assert checks.any? { |definition| definition.include?("row_count") && definition.include?("0") }
      assert checks.any? { |definition| definition.include?("expires_at") && definition.include?("data_cutoff_at") }
      %w[ready_at failed_at expiring_at expired_at].each do |timestamp|
        assert checks.any? { |definition| definition.include?(timestamp) && definition.include?("status") }
      end
      assert checks.any? do |definition|
        definition.include?("expired") && definition.include?("field_keys") &&
          definition.include?("filters") && definition.include?("IS NULL")
      end
    end

    test "binds exactly one private Active Storage file attachment" do
      reflection = AttendeeExport.reflect_on_attachment(:file)

      assert_equal [ :file ], AttendeeExport.reflect_on_all_attachments.map(&:name)
      assert_equal :private_exports, reflection.options.fetch(:service_name)
    end

    test "database rejects invalid rows when model validations are bypassed" do
      AttendeeExport.connection

      invalid_values = {
        status: "unknown",
        row_mode: "unknown",
        format_version: "csv_v2",
        reason_code: "unknown",
        field_set_digest: "x" * 64,
        filter_digest: "x" * 63,
        idempotency_key_digest: "x" * 63,
        request_fingerprint: "x" * 63,
        field_keys: {},
        attempt_count: 4,
        row_count: -1,
        expires_at: raw_attributes.fetch(:data_cutoff_at),
        ready_at: Time.current,
        filters: { "unknown" => [] }
      }

      invalid_values.each do |field, value|
        assert_database_rejects { AttendeeExport.insert_all!([ raw_attributes.merge(field => value) ]) }
      end

      assert_database_rejects do
        AttendeeExport.insert_all!([ raw_attributes.merge(status: "expired", expired_at: Time.current) ])
      end

      assert_database_rejects do
        AttendeeExport.insert_all!([ raw_attributes.merge(status: "ready", ready_at: Time.current) ])
      end

      assert_database_rejects do
        AttendeeExport.insert_all!([
          raw_attributes.merge(
            status: "expiring",
            expiring_at: Time.current,
            processing_started_at: Time.current
          )
        ])
      end

      assert_database_rejects do
        AttendeeExport.insert_all!([
          raw_attributes.merge(filters: { "ticket_type_ids" => Array.new(101) { SecureRandom.uuid } })
        ])
      end

      assert_database_rejects do
        AttendeeExport.insert_all!([
          raw_attributes.merge(filters: { "registration_statuses" => [ "archived" ] })
        ])
      end

      assert_database_rejects do
        attributes = raw_attributes
        AttendeeExport.insert_all!([ attributes ])
        AttendeeExport.insert_all!([ attributes.merge(id: SecureRandom.uuid) ])
      end
    end

    test "database rejects null required timestamps and lock state" do
      AttendeeExport.connection

      export = AttendeeExport.create!(base_attributes)
      %i[data_cutoff_at expires_at created_at updated_at attempt_count].each do |field|
        assert_database_rejects do
          AttendeeExport.where(id: export.id).update_all(field => nil)
        end
      end
      assert_database_rejects do
        sql = AttendeeExport.sanitize_sql_array([
          "UPDATE #{AttendeeExport.table_name} SET lock_version = NULL WHERE id = ?",
          export.id
        ])
        AttendeeExport.connection.execute(sql)
      end
    end

    test "requires every active request field" do
      required_fields = %i[
        event requested_by status row_mode format_version field_keys filters
        field_set_digest filter_digest reason_code data_cutoff_at expires_at
        idempotency_key_digest request_fingerprint digest_key_version
      ]

      required_fields.each do |field|
        export = AttendeeExport.new(base_attributes.except(field))
        assert_not export.valid?, "expected #{field} to be required"
      end
    end

    test "allows only launch status, row mode, format, and reason values" do
      {
        status: "queued",
        row_mode: "attendees",
        format_version: "csv_v2",
        reason_code: "free_form"
      }.each do |field, value|
        export = build_export(field => value)

        assert_not export.valid?, "expected #{field}=#{value.inspect} to be rejected"
        assert export.errors.key?(field)
      end
    end

    test "requires versioned HMAC-shaped digests and a file SHA-256 when present" do
      %i[field_set_digest filter_digest idempotency_key_digest request_fingerprint].each do |field|
        export = build_export(field => "not-a-digest")

        assert_not export.valid?, "expected #{field} to be rejected"
        assert export.errors.key?(field)
      end

      invalid_file_digest = build_export(file_sha256: "f" * 63)
      assert_not invalid_file_digest.valid?
      assert invalid_file_digest.errors.key?(:file_sha256)
    end

    test "allows only controlled generation failure codes" do
      invalid_failure = build_export(failure_code: "generation_failed")

      assert_not invalid_failure.valid?
      assert invalid_failure.errors.key?(:failure_code)
    end

    test "has a unique database index for the scoped idempotency digest" do
      index = AttendeeExport.connection.indexes(AttendeeExport.table_name).find do |candidate|
        candidate.unique && candidate.columns == [ "idempotency_key_digest" ]
      end

      assert index, "expected a unique idempotency_key_digest index"
    end

    test "requires field_keys to be an array with at most 100 selectors and filters to be an object" do
      invalid_field_keys = build_export(field_keys: {})
      assert_not invalid_field_keys.valid?
      assert invalid_field_keys.errors.key?(:field_keys)

      too_many_fields = Array.new(101) { |index| "question:#{SecureRandom.uuid}:field_#{index}" }
      oversized_field_set = build_export(field_keys: too_many_fields)
      assert_not oversized_field_set.valid?
      assert oversized_field_set.errors.key?(:field_keys)

      invalid_filters = build_export(filters: [])
      assert_not invalid_filters.valid?
      assert invalid_filters.errors.key?(:filters)
    end

    test "bounds filter arrays and registration statuses" do
      too_many_ticket_types = build_export(
        filters: { "ticket_type_ids" => Array.new(101) { SecureRandom.uuid } }
      )
      assert_not too_many_ticket_types.valid?
      assert too_many_ticket_types.errors.key?(:filters)

      invalid_status = build_export(filters: { "registration_statuses" => [ "archived" ] })
      assert_not invalid_status.valid?
      assert invalid_status.errors.key?(:filters)

      two_ticket_types = build_export(
        filters: {
          "ticket_type_ids" => [
            create_ticket_type(@event, "First valid filter ticket").id,
            create_ticket_type(@event, "Second valid filter ticket").id
          ]
        }
      )
      assert_predicate two_ticket_types, :valid?

      duplicate_ticket_type = SecureRandom.uuid
      duplicate_filter = build_export(
        filters: { "ticket_type_ids" => [ duplicate_ticket_type, duplicate_ticket_type ] }
      )
      assert_not duplicate_filter.valid?
      assert duplicate_filter.errors.key?(:filters)

      scalar_filter = build_export(filters: { "ticket_type_ids" => SecureRandom.uuid })
      assert_not scalar_filter.valid?
      assert scalar_filter.errors.key?(:filters)

      unknown_filter = build_export(filters: { "search" => "attendee" })
      assert_not unknown_filter.valid?
      assert unknown_filter.errors.key?(:filters)
    end

    test "represents OR-within and AND-across filters as unique route-owned arrays" do
      route_ticket_type = create_ticket_type(@event, "Filter route ticket")
      second_route_ticket_type = create_ticket_type(@event, "Second filter route ticket")
      route_date = create_event_date(@event)
      foreign_ticket_type = create_ticket_type(@other_event, "Foreign filter ticket")
      foreign_date = create_event_date(@other_event)
      filters = {
        "ticket_type_ids" => [ route_ticket_type.id, second_route_ticket_type.id ],
        "access_event_date_ids" => [ route_date.id ],
        "registration_statuses" => [ "confirmed", "offered" ]
      }

      export = build_export(filters: filters)
      assert_predicate export, :valid?
      assert_equal filters, export.filters

      foreign_ticket = build_export(filters: filters.merge("ticket_type_ids" => [ foreign_ticket_type.id ]))
      foreign_date_filter = build_export(filters: filters.merge("access_event_date_ids" => [ foreign_date.id ]))
      assert_not foreign_ticket.valid?
      assert_not foreign_date_filter.valid?
    end

    test "requires nonnegative rows, attempts between zero and three, and a bounded expiry" do
      negative_rows = build_export(row_count: -1)
      assert_not negative_rows.valid?
      assert negative_rows.errors.key?(:row_count)

      negative_attempts = build_export(attempt_count: -1)
      assert_not negative_attempts.valid?
      assert negative_attempts.errors.key?(:attempt_count)

      excessive_attempts = build_export(attempt_count: 4)
      assert_not excessive_attempts.valid?
      assert excessive_attempts.errors.key?(:attempt_count)

      cutoff = base_attributes.fetch(:data_cutoff_at)
      expired_before_cutoff = build_export(expires_at: cutoff)
      assert_not expired_before_cutoff.valid?
      assert expired_before_cutoff.errors.key?(:expires_at)

      expired_after_limit = build_export(expires_at: cutoff + 24.hours + 1.second)
      assert_not expired_after_limit.valid?
      assert expired_after_limit.errors.key?(:expires_at)
    end

    test "couples lifecycle timestamps and ready metadata to the status" do
      pending_with_ready_time = build_export(ready_at: Time.current)
      assert_not pending_with_ready_time.valid?

      ready_without_metadata = build_export(status: "ready")
      assert_not ready_without_metadata.valid?

      ready = build_export(
        status: "ready",
        processing_started_at: 1.minute.ago,
        attempt_count: 1,
        ready_at: Time.current,
        row_count: 0,
        file_sha256: "f" * 64
      )
      assert_predicate ready, :valid?

      failed_without_failed_at = build_export(status: "failed", failure_code: "generation_failed")
      assert_not failed_without_failed_at.valid?

      expiring_without_expiring_at = build_export(status: "expiring")
      assert_not expiring_without_expiring_at.valid?

      expired_without_expired_at = build_export(status: "expired", field_keys: nil, filters: nil)
      assert_not expired_without_expired_at.valid?

      expiring_with_processing_time = build_export(
        status: "expiring",
        processing_started_at: 1.minute.ago,
        expiring_at: Time.current
      )
      assert_not expiring_with_processing_time.valid?

      expired_with_stale_failure = build_export(
        status: "expired",
        field_keys: nil,
        filters: nil,
        failure_code: "export_generation_failed",
        expired_at: Time.current
      )
      assert_not expired_with_stale_failure.valid?
    end

    test "requires expired tombstone payload fields to be SQL NULL" do
      expired_with_empty_payload = build_export(
        status: "expired",
        field_keys: [],
        filters: {},
        expired_at: Time.current
      )

      assert_not expired_with_empty_payload.valid?
    end

    test "bounds expiry from request creation rather than data cutoff" do
      export = build_export(
        created_at: Time.current,
        data_cutoff_at: 2.days.ago,
        expires_at: 12.hours.from_now
      )

      assert_predicate export, :valid?
    end

    test "accepts a payload-free expired tombstone while retaining request digests" do
      tombstone = build_export(
        status: "expired",
        field_keys: nil,
        filters: nil,
        failure_code: nil,
        expired_at: Time.current,
        row_count: 4,
        file_sha256: "f" * 64
      )

      assert_predicate tombstone, :valid?
      assert_equal "a" * 64, tombstone.field_set_digest
      assert_equal "b" * 64, tombstone.filter_digest
      assert_equal "c" * 64, tombstone.idempotency_key_digest
      assert_equal "d" * 64, tombstone.request_fingerprint
    end

    test "requires selectors and filters in every non-expired state" do
      %w[pending processing ready failed expiring].each do |status|
        export = build_export(status:, field_keys: nil, filters: nil)

        assert_not export.valid?, "expected #{status} to retain its request payload"
      end
    end

    private

    def build_export(overrides = {})
      AttendeeExport.new(base_attributes.merge(overrides))
    end

    def base_attributes
      now = Time.current

      {
        event: @event,
        requested_by: @requester,
        status: "pending",
        row_mode: "registration",
        format_version: "csv_v1",
        field_keys: [ "registration_id" ],
        filters: {},
        field_set_digest: "a" * 64,
        filter_digest: "b" * 64,
        reason_code: "event_operations",
        data_cutoff_at: now,
        idempotency_key_digest: "c" * 64,
        request_fingerprint: "d" * 64,
        digest_key_version: "v1",
        attempt_count: 0,
        expires_at: now + 1.hour,
        lock_version: 0
      }
    end

    def raw_attributes
      now = Time.current

      {
        event_id: @event.id,
        requested_by_id: @requester.id,
        status: "pending",
        row_mode: "registration",
        format_version: "csv_v1",
        field_keys: [ "registration_id" ],
        filters: {},
        field_set_digest: "a" * 64,
        filter_digest: "b" * 64,
        reason_code: "event_operations",
        data_cutoff_at: now,
        idempotency_key_digest: SecureRandom.hex(32),
        request_fingerprint: "d" * 64,
        digest_key_version: "v1",
        attempt_count: 0,
        expires_at: now + 1.hour,
        lock_version: 0,
        created_at: now,
        updated_at: now
      }
    end

    def create_ticket_type(event, name)
      Catalog::Products::CreateDraft.call(
        event:,
        actor: @requester,
        product_attributes: { name:, type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
    end

    def create_event_date(event)
      starts_at = 1.month.from_now
      event.event_dates.create!(
        starts_at:,
        ends_at: starts_at + 2.hours,
        status: "scheduled"
      )
    end

    def schema_columns
      AttendeeExport.connection.select_all(<<~SQL).to_a.index_by { |row| row.fetch("column_name") }
        SELECT column_name, is_nullable, column_default, udt_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = '#{AttendeeExport.table_name}'
      SQL
    end

    def foreign_key_targets
      rows = AttendeeExport.connection.select_all(<<~SQL).to_a
        SELECT kcu.column_name,
               ccu.table_name AS referenced_table,
               ccu.column_name AS referenced_column
        FROM information_schema.table_constraints AS tc
        JOIN information_schema.key_column_usage AS kcu
          ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema = kcu.table_schema
        JOIN information_schema.constraint_column_usage AS ccu
          ON tc.constraint_name = ccu.constraint_name
         AND tc.table_schema = ccu.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = 'public'
          AND tc.table_name = '#{AttendeeExport.table_name}'
      SQL

      rows.to_h do |row|
        [ row.fetch("column_name"), [ row.fetch("referenced_table"), row.fetch("referenced_column") ] ]
      end
    end

    def index_definitions
      AttendeeExport.connection.select_values(<<~SQL)
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = '#{AttendeeExport.table_name}'
      SQL
    end

    def constraint_definitions
      AttendeeExport.connection.select_values(<<~SQL)
        SELECT pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conrelid = '#{AttendeeExport.table_name}'::regclass
          AND contype = 'c'
      SQL
    end

    def assert_database_rejects(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        AttendeeExport.transaction(requires_new: true, &block)
      end
    end
  end
end
