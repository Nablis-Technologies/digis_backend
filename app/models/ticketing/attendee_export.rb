# frozen_string_literal: true

module Ticketing
  # Stores the bounded, auditable request metadata for one private export.
  class AttendeeExport < Ticketing::ApplicationRecord
    self.table_name = "ticketing_attendee_exports"

    STATUSES = %w[pending processing ready failed expiring expired].freeze
    ROW_MODES = %w[registration admission].freeze
    FORMAT_VERSIONS = %w[csv_v1].freeze
    REASON_CODES = %w[
      event_operations attendee_communication dietary_accommodation
      accessibility_accommodation customer_support legal_compliance
    ].freeze
    REGISTRATION_STATUSES = Ticketing::Registration::STATUSES
    FILTER_KEYS = %w[ticket_type_ids access_event_date_ids registration_statuses].freeze
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    FAILURE_CODES = %w[export_too_large export_generation_failed export_storage_unavailable].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :requested_by, class_name: "Core::User"

    has_one_attached :file, service: :private_exports

    validates :event, :requested_by, :status, :row_mode, :format_version,
              :field_set_digest, :filter_digest, :reason_code, :data_cutoff_at,
              :expires_at, :idempotency_key_digest, :request_fingerprint,
              :digest_key_version, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :row_mode, inclusion: { in: ROW_MODES }
    validates :format_version, inclusion: { in: FORMAT_VERSIONS }
    validates :reason_code, inclusion: { in: REASON_CODES }
    validates :field_set_digest, :filter_digest, :idempotency_key_digest,
              :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :file_sha256, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
    validates :attempt_count, numericality: { only_integer: true, in: 0..3 }
    validates :row_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :failure_code, inclusion: { in: FAILURE_CODES }, allow_nil: true

    validate :field_keys_contract
    validate :filters_contract
    validate :route_owned_filters
    validate :expiry_window
    validate :state_timestamps
    validate :payload_state
    validate :ready_metadata

    scope :active, -> { where.not(status: "expired") }
    scope :due_for_expiry, -> { where("expires_at <= ?", Time.current) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id requested_by_id status row_mode format_version field_set_digest
        filter_digest reason_code data_cutoff_at row_count file_sha256
        idempotency_key_digest request_fingerprint digest_key_version processing_started_at
        attempt_count ready_at failed_at expiring_at expired_at expires_at
        last_download_authorized_at failure_code lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event requested_by]
    end

    private

    def field_keys_contract
      return if status == "expired" && field_keys.nil?
      unless field_keys.is_a?(Array) && field_keys.length <= 100 && field_keys.all? { |key| key.is_a?(String) && key.present? } && field_keys.uniq.length == field_keys.length
        add_export_error(:field_keys, :invalid_field_keys)
      end
    end

    def filters_contract
      return if status == "expired" && filters.nil?
      unless filters.is_a?(Hash) && filters.keys.all? { |key| FILTER_KEYS.include?(key.to_s) }
        add_export_error(:filters, :invalid_filters)
        return
      end

      FILTER_KEYS.each do |key|
        next unless filters.key?(key) || filters.key?(key.to_sym)

        values = filter_values(key)
        unless values.is_a?(Array) && values.length <= 100 && values.uniq.length == values.length
          add_export_error(:filters, :invalid_filters)
        end
      end

      validate_uuid_filter(:ticket_type_ids)
      validate_uuid_filter(:access_event_date_ids)
      statuses = filter_values(:registration_statuses)
      if statuses && (!statuses.is_a?(Array) || statuses.any? { |status| !REGISTRATION_STATUSES.include?(status) })
        add_export_error(:filters, :invalid_filters)
      end
    end

    def route_owned_filters
      return if event.blank? || filters.blank?

      ticket_type_ids = filter_values(:ticket_type_ids)
      if ticket_type_ids.is_a?(Array) && ticket_type_ids.all? { |value| value.is_a?(String) && value.match?(UUID_PATTERN) } &&
          Ticketing::TicketType.joins(:event_product).where(id: ticket_type_ids, catalog_event_products: { event_id: event.id }).count != ticket_type_ids.length
        add_export_error(:filters, :invalid_filters)
      end

      date_ids = filter_values(:access_event_date_ids)
      if date_ids.is_a?(Array) && date_ids.all? { |value| value.is_a?(String) && value.match?(UUID_PATTERN) } &&
          Events::EventDate.where(id: date_ids, event_id: event.id).count != date_ids.length
        add_export_error(:filters, :invalid_filters)
      end
    end

    def validate_uuid_filter(key)
      values = filter_values(key)
      return if values.nil?
      unless values.is_a?(Array)
        add_export_error(:filters, :invalid_filters)
        return
      end
      return if values.all? { |value| value.is_a?(String) && value.match?(UUID_PATTERN) }

      add_export_error(:filters, :invalid_filters)
    end

    def filter_values(key)
      return if filters.blank?

      filters[key.to_s] || filters[key]
    end

    def expiry_window
      return if data_cutoff_at.blank? || expires_at.blank?
      request_at = created_at || Time.current
      return if expires_at > data_cutoff_at && expires_at <= request_at + 24.hours

      add_export_error(:expires_at, :invalid_expiry)
    end

    def state_timestamps
      expected = {
        "pending" => { processing_started_at: false, ready_at: false, failed_at: false, expiring_at: false, expired_at: false },
        "processing" => { processing_started_at: true, ready_at: false, failed_at: false, expiring_at: false, expired_at: false },
        "ready" => { processing_started_at: true, ready_at: true, failed_at: false, expiring_at: false, expired_at: false },
        "failed" => { processing_started_at: true, ready_at: false, failed_at: true, expiring_at: false, expired_at: false },
        "expiring" => { processing_started_at: false, ready_at: false, failed_at: false, expiring_at: true, expired_at: false },
        "expired" => { processing_started_at: false, ready_at: false, failed_at: false, expiring_at: false, expired_at: true }
      }.fetch(status, {})

      expected.each do |attribute, required|
        present = public_send(attribute).present?
        add_export_error(attribute, :invalid_state) if present != required
      end
    end

    def payload_state
      # Expired tombstones retain digests and lifecycle evidence, never selectors or filters.
      if status == "expired"
        add_export_error(:field_keys, :invalid_payload_state) unless field_keys.nil?
        add_export_error(:filters, :invalid_payload_state) unless filters.nil?
        add_export_error(:failure_code, :invalid_payload_state) if failure_code.present?
      elsif field_keys.nil? || filters.nil?
        add_export_error(:base, :invalid_payload_state)
      end
    end

    def ready_metadata
      return unless status == "ready"
      add_export_error(:row_count, :ready_metadata_required) if row_count.nil?
      add_export_error(:file_sha256, :ready_metadata_required) if file_sha256.blank?
    end

    def add_export_error(attribute, key)
      errors.add(attribute, I18n.t("ticketing.attendee_exports.errors.#{key}"))
    end
  end
end
