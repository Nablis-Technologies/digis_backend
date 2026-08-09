  # frozen_string_literal: true

  module Ticketing
    module Waitlist
      # Shared queue and inventory-locking rules for waitlist commands. The
      # registration remains the queue row; no parallel waitlist table is used.
      module Support
      include Ticketing::Registrations::Support

      private

      def waitlist_error(code)
        workflow_error(code)
      end

      def waitlist_audit_key(action, registration, idempotency_key)
        digest = Core::IdempotencyKey.new(idempotency_key).digest
        "ticketing-waitlist-#{action}-#{registration.id}-#{digest}"
      end

      def waitlist_audit!(action:, audit_key:, registration:, actor:, audited_changes:, metadata: {})
        unwrap(Core::Audit::Record.call(
          audit_key:,
          action: "ticketing.registration.#{action}",
          auditable_type: registration.class.name,
          auditable_id: registration.id,
          actor_type: actor&.class&.name,
          actor_id: actor&.id,
          audited_changes:,
          metadata: metadata.merge(event_id: registration.event_id)
        ))
      end

      def waitlist_replay(audit_key)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        Ticketing::Registration.find(audit.auditable_id)
      end

      def buyer_actor?(registration, actor)
        actor.is_a?(Core::User) && actor.verified_at.present? && actor.id == registration.user_id
      end

      def inventory_fits?(product, registration, inventories)
        # This is a locked preflight; Reserve performs the authoritative
        # capacity check, including venue capacity shared by other products.
        quantity = registration.package_quantity
        case product.inventory_mode
        when "unlimited"
          true
        when "event_wide"
          inventories.any? { |inventory| inventory.event_date_id.nil? && inventory.available_quantity >= quantity }
        when "per_date"
          inventories.present? && inventories.all? { |inventory| inventory.available_quantity >= quantity }
        when "event_wide_and_per_date"
          inventories.present? && inventories.all? { |inventory| inventory.available_quantity >= quantity }
        else
          false
        end
      end

      def lock_product_inventories(product, registration)
        # Lock dates and inventory in deterministic order before selecting a
        # candidate so concurrent offer workers cannot oversell a party.
        date_ids = registration.ticket_type.covered_date_ids(registration)
        Events::EventDate.where(id: date_ids).order(:id).lock.to_a
        return [] if product.inventory_mode == "unlimited"

        product.inventories
          .where(event_date_id: [ nil, *date_ids ])
          .order(:id)
          .lock
          .to_a
      end

      def candidate_scope(ticket_type, selected_event_date_id, excluded_ids)
        # SKIP LOCKED lets another worker move past a candidate it is already
        # processing instead of creating a duplicate offer or waiting forever.
        scope = Ticketing::Registration
          .where(ticket_type_id: ticket_type.id, status: "waitlisted")
        scope = if selected_event_date_id.present?
          scope.where(selected_event_date_id: selected_event_date_id)
        else
          scope.where(selected_event_date_id: nil)
        end
        scope = scope.where.not(id: excluded_ids) if excluded_ids.present?
        scope.order(:waitlisted_at, :id).limit(1).lock("FOR UPDATE SKIP LOCKED")
      end
      end
    end
  end
