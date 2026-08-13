# frozen_string_literal: true

module Ticketing
  module ScannerSync
    # Builds the complete scanner state while holding the event lock. The
    # lock makes the four cursor versions and their rows one atomic snapshot;
    # downloading it never acknowledges or advances the assignment cursor.
    class BuildSnapshot < Core::BaseService
      def initialize(assignment:)
        @assignment = assignment
      end

      def call
        payload = nil
        Events::Event.transaction do
          event = Events::Event.lock.find(@assignment.event_id)
          payload = snapshot_payload(event)
        end
        success(payload)
      rescue ActiveRecord::RecordNotFound
        failure(scanner_error(:event_not_found, :not_found))
      end

      protected

      attr_reader :assignment

      def snapshot_payload(event)
        {
          contract_version: 1,
          event_id: event.id.to_s,
          sync_mode: "full",
          versions: current_versions(event),
          signing_keys: Ticketing::Qr::Verifier.public_keys,
          package_revocations: {
            version: current_versions(event).fetch(:revocations),
            changed: package_revocations(event).map { |row| ScannerSyncSerializer.package_revocation(row) }
          },
          credential_revocations: {
            version: current_versions(event).fetch(:revocations),
            changed: credential_revocations(event).map { |row| ScannerSyncSerializer.credential_revocation(row) }
          },
          attendee_index: {
            version: current_versions(event).fetch(:attendee_index),
            changed: attendee_entries(event).map { |row| ScannerSyncSerializer.attendee_index_entry(row) }
          },
          schedule: schedule_payload(event),
          server_use_ids: admission_uses(event).map { |row| ScannerSyncSerializer.admission_use(row) },
          admission_use_reversals: {
            version: current_versions(event).fetch(:reversals),
            changed: reversals(event).map { |row| ScannerSyncSerializer.reversal(row) }
          }
        }
      end

      def current_versions(event)
        {
          revocations: event.revocation_version.to_i,
          attendee_index: event.attendee_index_version.to_i,
          schedule: event.schedule_version.to_i,
          reversals: event.admission_use_reversal_version.to_i
        }
      end

      def package_revocations(event, since: nil)
        scope = Ticketing::Revocation.where(event_id: event.id)
        scope = scope.where("revocation_version > ?", since) if since
        scope.order(:revocation_version, :id).to_a
      end

      def credential_revocations(event, since: nil)
        scope = Ticketing::CredentialRevocation.where(event_id: event.id)
        scope = scope.where("revocation_version > ?", since) if since
        scope.order(:revocation_version, :id).to_a
      end

      def attendee_entries(event, since: nil)
        scope = Ticketing::AttendeeIndexEntry.where(event_id: event.id, removed: false)
        scope = scope.where("index_version > ?", since) if since
        scope.order(:index_version, :id).to_a
      end

      def reversals(event, since: nil)
        scope = Ticketing::AdmissionUseReversal.where(event_id: event.id)
        scope = scope.where("reversal_version > ?", since) if since
        scope.order(:reversal_version, :id).to_a
      end

      def schedule_payload(event)
        versions = current_versions(event)
        {
          version: versions.fetch(:schedule),
          event_dates: event.event_dates.order(:starts_at, :id).pluck(
            :id, :name, :doors_at, :starts_at, :ends_at, :status
          ).map do |id, name, doors_at, starts_at, ends_at, status|
            {
              id: id.to_s,
              name: name,
              doors_at: doors_at&.iso8601,
              starts_at: starts_at.iso8601,
              ends_at: ends_at.iso8601,
              status: status
            }
          end,
          access_zones: Events::AccessZone.where(event_id: event.id).order(:sort_order, :id).pluck(
            :id, :event_date_id, :type, :name, :code, :active, :sort_order
          ).map do |id, event_date_id, type, name, code, active, sort_order|
            {
              id: id.to_s,
              event_date_id: event_date_id&.to_s,
              type: type,
              name: name,
              code: code,
              active: active,
              sort_order: sort_order
            }
          end,
          product_access_zones: Catalog::ProductAccessZone.joins(product_access: :event_product)
            .where(catalog_event_products: { event_id: event.id })
            .order(:product_access_id, :access_zone_id)
            .pluck(:product_access_id, :access_zone_id)
            .map { |product_access_id, access_zone_id| { product_access_id: product_access_id.to_s, access_zone_id: access_zone_id.to_s } },
          scanner_assignment_zones: @assignment.assignment_zones.order(:access_zone_id).pluck(:access_zone_id)
            .map { |access_zone_id| { access_zone_id: access_zone_id.to_s } }
        }
      end

      def admission_uses(event, ids: nil)
        scope = Ticketing::AdmissionUse.joins(:credential).where(ticketing_credentials: { event_id: event.id })
        scope = scope.where(id: ids) if ids
        scope.order(:id).to_a
      end

      def scanner_error(key, status = :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner_sync.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
