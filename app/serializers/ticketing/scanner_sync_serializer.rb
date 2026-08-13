# frozen_string_literal: true

module Ticketing
  # Serializes the deliberately small scanner synchronization contract. This
  # is a plain serializer because the feed is a composite of projections rather
  # than one ActiveRecord resource; every nested allowlist is a privacy boundary.
  class ScannerSyncSerializer
    TOP_LEVEL_KEYS = %i[
      contract_version event_id sync_mode versions signing_keys package_revocations
      credential_revocations attendee_index schedule server_use_ids admission_use_reversals
    ].freeze

    def self.call(payload)
      new(payload).as_json
    end

    def self.attendee_index_entry(entry)
      attributes = {
        credential_id: entry.credential_id.to_s,
        ticket_id: entry.ticket_id.to_s,
        lookup_code: entry.lookup_code,
        phone_hash: entry.phone_hash,
        owner_phone_hash: entry.owner_phone_hash,
        holder_name: entry.entry_validation_mode == "qr_and_id" ? entry.holder_name : nil,
        slot_positions: Array(entry.slot_positions).map(&:to_i),
        credential_mode: entry.credential_mode,
        generation_version: entry.generation_version,
        entry_limit: entry.entry_limit,
        ticket_type: entry.ticket_type,
        ticket_type_label: entry.ticket_type_label,
        perks: entry.perks,
        product_access_ids: Array(entry.product_access_ids).map(&:to_s),
        entry_validation_mode: entry.entry_validation_mode,
        index_version: entry.index_version,
        removed: entry.removed
      }
      attributes.compact
    end

    def self.package_revocation(revocation)
      {
        tid: revocation.ticket_id.to_s,
        revoked_through_version: revocation.revoked_through_version,
        is_dead: revocation.is_dead,
        is_suspended: revocation.is_suspended,
        revocation_version: revocation.revocation_version
      }
    end

    def self.credential_revocation(revocation)
      {
        cid: revocation.credential_id.to_s,
        reason: revocation.reason,
        revoked_at: revocation.revoked_at&.iso8601,
        revocation_version: revocation.revocation_version
      }
    end

    def self.reversal(reversal)
      {
        admission_use_id: reversal.admission_use_id.to_s,
        checkin_log_id: reversal.checkin_log_id.to_s,
        reversal_group_id: reversal.reversal_group_id.to_s,
        reversal_version: reversal.reversal_version,
        reversed_at: reversal.reversed_at&.iso8601,
        reason_code: reversal.reason_code
      }
    end

    def self.admission_use(admission_use)
      if admission_use.respond_to?(:id)
        {
          id: admission_use.id.to_s,
          admission_slot_id: admission_use.admission_slot_id.to_s,
          product_access_id: admission_use.product_access_id.to_s,
          credential_id: admission_use.credential_id.to_s,
          usage_number: admission_use.usage_number,
          used_at: admission_use.used_at&.iso8601
        }
      else
        admission_use.to_h.symbolize_keys.slice(
          :id, :admission_slot_id, :product_access_id, :credential_id, :usage_number, :used_at
        )
      end
    end

    def self.stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          result[key.to_s] = stringify_keys(nested)
        end
      when Array
        value.map { |nested| stringify_keys(nested) }
      else
        value
      end
    end

    def initialize(payload)
      @payload = payload.deep_symbolize_keys
    end

    def as_json(*)
      {
        "contract_version" => @payload.fetch(:contract_version),
        "event_id" => @payload.fetch(:event_id).to_s,
        "sync_mode" => @payload.fetch(:sync_mode).to_s,
        "versions" => versions,
        "signing_keys" => stringify_keys(@payload.fetch(:signing_keys)),
        "package_revocations" => revocation_feed(@payload.fetch(:package_revocations)),
        "credential_revocations" => credential_feed(@payload.fetch(:credential_revocations)),
        "attendee_index" => attendee_feed(@payload.fetch(:attendee_index)),
        "schedule" => schedule,
        "server_use_ids" => Array(@payload.fetch(:server_use_ids)).map { |use| self.class.admission_use(use) },
        "admission_use_reversals" => reversal_feed(@payload.fetch(:admission_use_reversals))
      }
    end

    private

    def stringify_keys(value)
      self.class.stringify_keys(value)
    end

    def versions
      stringify_keys(@payload.fetch(:versions).slice(:revocations, :attendee_index, :schedule, :reversals))
    end

    def revocation_feed(feed)
      {
        "version" => feed.fetch(:version),
        "changed" => Array(feed[:changed]).map do |entry|
          value = if entry.is_a?(Ticketing::Revocation)
            self.class.package_revocation(entry)
          else
            entry.to_h.symbolize_keys.slice(
              :tid, :revoked_through_version, :is_dead, :is_suspended, :revocation_version
            )
          end
          stringify_keys(value)
        end
      }
    end

    def credential_feed(feed)
      {
        "version" => feed.fetch(:version),
        "changed" => Array(feed[:changed]).map do |entry|
          value = if entry.is_a?(Ticketing::CredentialRevocation)
            self.class.credential_revocation(entry)
          else
            entry.to_h.symbolize_keys.slice(:cid, :reason, :revoked_at, :revocation_version)
          end
          stringify_keys(value)
        end
      }
    end

    def attendee_feed(feed)
      {
        "version" => feed.fetch(:version),
        "changed" => Array(feed[:changed]).map do |entry|
          entry.is_a?(Ticketing::AttendeeIndexEntry) ? self.class.attendee_index_entry(entry) : attendee_hash(entry)
        end
      }
    end

    def attendee_hash(entry)
      allowed = %i[
        credential_id ticket_id lookup_code phone_hash owner_phone_hash holder_name slot_positions
        credential_mode generation_version entry_limit ticket_type ticket_type_label perks
        product_access_ids entry_validation_mode index_version removed
      ]
      stringify_keys(entry.slice(*allowed).compact)
    end

    def schedule
      feed = @payload.fetch(:schedule)
      {
        "version" => feed.fetch(:version),
        "event_dates" => stringify_keys(Array(feed[:event_dates])),
        "access_zones" => stringify_keys(Array(feed[:access_zones])),
        "product_access_zones" => stringify_keys(Array(feed[:product_access_zones])),
        "scanner_assignment_zones" => stringify_keys(Array(feed[:scanner_assignment_zones]))
      }
    end

    def reversal_feed(feed)
      {
        "version" => feed.fetch(:version),
        "changed" => Array(feed[:changed]).map do |entry|
          value = entry.is_a?(Ticketing::AdmissionUseReversal) ? self.class.reversal(entry) : reversal_hash(entry)
          stringify_keys(value)
        end
      }
    end

    def reversal_hash(entry)
      allowed = %i[admission_use_id checkin_log_id reversal_group_id reversal_version reversed_at reason_code]
      stringify_keys(entry.slice(*allowed).compact)
    end
  end
end
