# frozen_string_literal: true

module Ticketing
  # Returns the event-owned scanner roster as separate invitation and active
  # assignment projections; contact details and credential material stay private.
  class ScannerRostersController < Ticketing::ApplicationController
    def index
      event = Events::Event.find(params[:event_id])
      authorize event, :index?, policy_class: Ticketing::ScannerRosterPolicy

      invitations = Ticketing::ScannerInvitation.where(event_id: event.id).order(:created_at, :id).to_a
      assignments = Ticketing::ScannerDeviceAssignment
        .joins(:event_staff_assignment)
        .where(event_id: event.id, events_event_staff_assignments: { role: "scanner" })
        .includes(:scanner_device, event_staff_assignment: :user, assignment_zones: :access_zone)
        .order(:created_at, :id)
        .to_a
      invitation_by_staff_assignment = Ticketing::ScannerInvitation
        .where(event_staff_assignment_id: assignments.map(&:event_staff_assignment_id))
        .index_by(&:event_staff_assignment_id)
      scan_counts = if assignments.empty?
        {}
      else
        Ticketing::CheckinLog.where(scanner_device_assignment_id: assignments.map(&:id))
          .group(:scanner_device_assignment_id).count
      end

      response.headers["Cache-Control"] = "private, no-store"
      render_success(data: {
        event_id: event.id,
        invitations: invitations.map { |invitation| invitation_payload(invitation) },
        assignments: assignments.map do |assignment|
          assignment_payload(assignment, invitation_by_staff_assignment[assignment.event_staff_assignment_id],
            scan_counts.fetch(assignment.id, 0))
        end
      })
    rescue ActiveRecord::RecordNotFound
      render_error(
        :"ticketing.scanner_sync.errors.event_not_found",
        status: :not_found,
        code: "event_not_found"
      )
    end

    private

    def invitation_payload(invitation)
      {
        id: invitation.id,
        masked_phone: invitation.masked_phone,
        display_label: invitation.display_label,
        note: invitation.organizer_note,
        status: invitation.effective_status,
        delivery_status: invitation.delivery_status,
        delivery_revision: invitation.delivery_revision,
        zone_mode: invitation.zone_mode,
        selected_zone_ids: invitation.selected_zone_ids,
        starts_at: invitation.starts_at,
        ends_at: invitation.ends_at,
        expires_at: invitation.expires_at,
        created_at: invitation.created_at
      }
    end

    def assignment_payload(assignment, invitation, scan_count)
      operator = assignment.event_staff_assignment.user
      zones = assignment.assignment_zones.map(&:access_zone).sort_by { |zone| [ zone.sort_order, zone.id ] }
      {
        id: assignment.id,
        event_staff_assignment_id: assignment.event_staff_assignment_id,
        scanner_device_id: assignment.scanner_device_id,
        scanner_name: assignment.scanner_device.name,
        display_label: invitation&.display_label,
        masked_phone: Ticketing::ScannerInvitation.mask_phone(operator.phone),
        invitation_status: invitation&.effective_status,
        status: effective_assignment_status(assignment),
        starts_at: assignment.starts_at,
        ends_at: assignment.ends_at,
        last_seen_at: assignment.scanner_device.last_seen_at,
        scan_count:,
        zones: zones.map do |zone|
          { id: zone.id, name: zone.name, code: zone.code }
        end
      }
    end

    def effective_assignment_status(assignment)
      return "expired" if assignment.active? && assignment.ends_at.present? && assignment.ends_at <= Time.current

      assignment.status
    end
  end
end
