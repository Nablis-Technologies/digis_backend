# frozen_string_literal: true

require "set"

module Ticketing
  module CredentialGenerations
    # Atomically replaces the one active credential set for a commercial
    # package. Ticket and slot locks serialize competing transitions; the
    # ticket pointer is moved before usable credentials are inserted to satisfy
    # the database shape guard, while the old generation is retained as a
    # revoked, scanner-visible history row.
    class Replace < Core::BaseService
      def initialize(ticket:, target_mode:, reason:, assignments:, idempotency_key:)
        @ticket = ticket
        @target_mode = target_mode.to_s
        @reason = reason.to_s.strip
        @raw_assignments = assignments
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      rescue ArgumentError => error
        @idempotency_key_error = error
      end

      def call
        return failure(invalid_idempotency_key) if @idempotency_key_error

        outcome = nil
        Ticketing::Ticket.transaction do
          ticket = load_ticket
          replay = replayed_generation(ticket)
          if replay
            outcome = replay
            next
          end

          assignments = normalize_assignments
          if assignments.failure?
            outcome = assignments
            raise ActiveRecord::Rollback
          end

          slots = ticket.admission_slots.order(:position).lock.to_a
          current_use_guard = lock_current_access_uses(ticket, slots)
          if current_use_guard.failure?
            outcome = current_use_guard
            raise ActiveRecord::Rollback
          end
          verification = verify_transition(ticket, assignments.value, slots)
          if verification.failure?
            outcome = verification
            raise ActiveRecord::Rollback
          end
          if current_assignment?(ticket.current_credential_generation, assignments.value)
            outcome = success(ticket.current_credential_generation)
            next
          end

          prior = ticket.credential_generations.includes(:credentials).lock.find_by!(status: "active")
          revocation = Ticketing::Revocations::PublishGeneration.call(
            ticket:, through_version: prior.version, reason: @reason
          )
          if revocation.failure?
            outcome = failure(revocation.error)
            raise ActiveRecord::Rollback
          end

          generation = ticket.credential_generations.create!(
            version: prior.version + 1,
            mode: @target_mode,
            status: "active",
            activated_at: Time.current
          )
          ticket.update!(
            credential_mode: @target_mode,
            credential_version: generation.version,
            current_credential_generation: generation
          )
          update_slots!(slots, assignments.value)
          credentials = create_credentials!(ticket, generation, slots, assignments.value)

          index = Ticketing::AttendeeIndex::ApplyGeneration.call(
            old_generation: prior, new_generation: generation
          )
          if index.failure?
            outcome = failure(index.error)
            raise ActiveRecord::Rollback
          end

          activation = activate_credentials!(ticket, credentials)
          if activation.failure?
            outcome = failure(activation.error)
            raise ActiveRecord::Rollback
          end

          publication = publish_replacement!(ticket, generation)
          outcome = failure(publication.error) and raise ActiveRecord::Rollback if publication.failure?
          outcome = success(reload_generation(generation))
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(replacement_error(:ticket_not_found, "ticket_not_found", :not_found))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          replacement_error(
            :generation_replacement_failed,
            "generation_replacement_failed",
            :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      rescue ActiveRecord::RecordNotUnique
        failure(replacement_error(:generation_conflict, "generation_conflict", :conflict))
      rescue Core::Outbox::IdempotencyConflict
        failure(replacement_error(:generation_idempotency_conflict, "generation_idempotency_conflict", :conflict))
      end

      private

      def load_ticket
        Ticketing::Ticket.includes(
          :event,
          :owner_user,
          :revocation,
          current_credential_generation: :credentials,
          admission_slots: :assigned_user,
          registration: :consent_requirements,
          event_product: [ :ticket_type, { product_accesses: :event_date } ]
        ).lock.find(@ticket.id)
      end

      def replayed_generation(ticket)
        event = Core::OutboxEvent.lock.find_by(idempotency_key: @idempotency_key.to_s)
        return unless event

        expected = {
          "topic" => "ticketing",
          "event_type" => "ticketing.credential_generation_replaced",
          "aggregate_type" => "Ticketing::Ticket",
          "aggregate_id" => ticket.id,
          "ticket_id" => ticket.id
        }
        matches = event.topic == expected["topic"] && event.event_type == expected["event_type"] &&
          event.aggregate_type == expected["aggregate_type"] && event.aggregate_id == expected["aggregate_id"] &&
          event.payload["ticket_id"] == expected["ticket_id"]
        return failure(replacement_error(:generation_idempotency_conflict, "generation_idempotency_conflict", :conflict)) unless matches

        version = Integer(event.payload.fetch("version"))
        generation = ticket.credential_generations.includes(credentials: :admission_slot).find_by(version:)
        return failure(replacement_error(:generation_idempotency_conflict, "generation_idempotency_conflict", :conflict)) unless generation

        success(generation)
      rescue ArgumentError, KeyError
        failure(replacement_error(:generation_idempotency_conflict, "generation_idempotency_conflict", :conflict))
      end

      def normalize_assignments
        raw = @raw_assignments
        return failure(replacement_error(:invalid_generation_assignments, "invalid_generation_assignments", :unprocessable_entity)) unless raw.is_a?(Hash)

        normalized = {}
        raw.each do |position, user|
          number = Integer(position)
          return failure(replacement_error(:invalid_generation_assignments, "invalid_generation_assignments", :unprocessable_entity)) unless number.positive?
          return failure(replacement_error(:invalid_generation_assignments, "invalid_generation_assignments", :unprocessable_entity)) if normalized.key?(number)
          return failure(replacement_error(:invalid_generation_assignments, "invalid_generation_assignments", :unprocessable_entity)) unless user.nil? || user.is_a?(Core::User)

          normalized[number] = user
        rescue ArgumentError, TypeError
          return failure(replacement_error(:invalid_generation_assignments, "invalid_generation_assignments", :unprocessable_entity))
        end
        success(normalized)
      end

      def verify_transition(ticket, assignments, slots)
        return failure(replacement_error(:invalid_generation_mode, "invalid_generation_mode", :unprocessable_entity)) unless
          Ticketing::Ticket::CREDENTIAL_MODES.include?(@target_mode)
        return failure(replacement_error(:revocation_reason_required, "revocation_reason_required", :unprocessable_entity)) if @reason.blank?
        return failure(replacement_error(:package_dead, "package_dead", :conflict)) if ticket.package_dead?
        return failure(replacement_error(:ticket_suspended, "ticket_suspended", :conflict)) if ticket.package_suspended?
        return failure(replacement_error(:ticket_not_active, "ticket_not_active", :conflict)) unless ticket.status == "active"
        return failure(replacement_error(:event_not_active, "event_not_active", :conflict)) if ticket.event.status.in?(%w[cancelled completed])
        return failure(replacement_error(:generation_not_current, "generation_not_current", :conflict)) unless current_generation_matches_ticket?(ticket)
        return failure(replacement_error(:invalid_generation_slots, "invalid_generation_slots", :conflict)) unless valid_slots?(ticket, slots)
        return failure(replacement_error(:delegation_not_enabled, "delegation_not_enabled", :unprocessable_entity)) if
          @target_mode == "delegated" && !ticket.event_product.ticket_type.delegation_enabled?
        return failure(replacement_error(:invalid_generation_assignments, "invalid_generation_assignments", :unprocessable_entity)) unless
          valid_assignment_shape?(assignments, slots)
        return failure(replacement_error(:generation_cutoff_passed, "generation_cutoff_passed", :conflict)) if cutoff_passed?(ticket)

        success(true)
      end

      def valid_assignment_shape?(assignments, slots)
        positions = slots.map(&:position)
        @target_mode == "group" ? assignments.empty? : assignments.keys.sort == positions
      end

      def valid_slots?(ticket, slots)
        slots.map(&:position) == (1..ticket.admissions_per_unit_snapshot).to_a
      end

      def current_generation_matches_ticket?(ticket)
        generation = ticket.current_credential_generation
        generation&.status == "active" && generation.id == ticket.current_credential_generation_id &&
          generation.version == ticket.credential_version && generation.mode == ticket.credential_mode
      end

      def current_assignment?(generation, assignments)
        return false unless generation&.mode == @target_mode
        return false if @target_mode == "group"

        generation.credentials.includes(:admission_slot).all? do |credential|
          position = credential.admission_slot.position
          credential.holder_user_id == assignments[position]&.id && credential.status != "revoked"
        end
      end

      def lock_current_access_uses(ticket, slots)
        connection = Ticketing::ApplicationRecord.connection
        return success(false) unless connection.data_source_exists?("ticketing_admission_uses")

        now = Time.current
        slot_ids = slots.map(&:id)
        sql = <<~SQL
          SELECT admission_uses.id
            FROM ticketing_admission_uses admission_uses
            JOIN catalog_product_accesses product_accesses
              ON product_accesses.id = admission_uses.product_access_id
            JOIN events_event_dates event_dates
              ON event_dates.id = product_accesses.event_date_id
           WHERE admission_uses.admission_slot_id IN (?)
             AND event_dates.event_id = ?
             AND event_dates.status = 'scheduled'
             AND event_dates.starts_at <= ?
             AND event_dates.ends_at > ?
           FOR UPDATE
        SQL
        query = Ticketing::ApplicationRecord.sanitize_sql_array([ sql, slot_ids, ticket.event_id, now, now ])
        current_uses = connection.select_values(query)
        return success(false) if current_uses.empty?

        failure(replacement_error(:generation_current_access_used, "generation_current_access_used", :conflict))
      end

      def cutoff_passed?(ticket)
        dates = ticket.event_product.product_accesses.map(&:event_date).compact.reject { |date| date.status == "cancelled" }
        return false if dates.empty?

        seconds = ticket.event_product.ticket_type.transfer_cutoff_seconds_before_start.to_i
        Time.current >= dates.map { |date| date.starts_at - seconds.seconds }.min
      end

      def create_credentials!(ticket, generation, slots, assignments)
        if @target_mode == "group"
          [ generation.credentials.create!(
            ticket:, event: ticket.event, type: "package", status: "pending_requirements",
            slot_positions: slots.map(&:position), entry_limit: slots.length
          ) ]
        else
          slots.map do |slot|
            user = assignments.fetch(slot.position)
            generation.credentials.create!(
              ticket:, event: ticket.event, admission_slot: slot, holder_user: user,
              type: "individual", status: user ? "pending_requirements" : "pending_claim",
              slot_positions: [ slot.position ], entry_limit: 1
            )
          end
        end
      end

      def activate_credentials!(ticket, credentials)
        context = {
          reserved_lookup_codes: Ticketing::Credential.where(event_id: ticket.event_id).where.not(lookup_code: nil).pluck(:lookup_code).to_set,
          next_index_version: Ticketing::AttendeeIndexEntry.where(event_id: ticket.event_id).maximum(:index_version).to_i + 1
        }
        credentials.each do |credential|
          next unless activatable_credential?(ticket, credential)

          activation = Ticketing::Credentials::Activate.call(
            credential:, loaded_credential: credential, issuance_context: context
          )
          return activation if activation.failure?
        end
        success(credentials)
      end

      def activatable_credential?(ticket, credential)
        return false unless credential.status == "pending_requirements"
        return false if identity_name_required?(ticket)
        return true unless ticket.registration_id

        !ticket.registration.consent_requirements.any? do |requirement|
          requirement.required? && requirement.acceptance_scope == "admission_slot" &&
            requirement.package_unit_number == ticket.unit_number &&
            (credential.type == "package" || requirement.admission_position == credential.admission_slot.position) &&
            (requirement.pending? ||
              requirement.subject_user_id.present? && requirement.subject_user_id != credential.holder_user_id)
        end
      end

      def identity_name_required?(ticket)
        ticket.event_product.ticket_type.entry_validation_mode == "qr_and_id"
      end

      def update_slots!(slots, assignments)
        now = Time.current
        slots.each do |slot|
          user = assignments[slot.position]
          slot.update!(
            assigned_user: user,
            assignment_status: user ? "claimed" : (@target_mode == "delegated" ? "pending_claim" : "unassigned"),
            claimed_at: user ? now : nil
          )
        end
      end

      def publish_replacement!(ticket, generation)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.credential_generation_replaced",
          aggregate: ticket,
          payload: { ticket_id: ticket.id, version: generation.version },
          idempotency_key: @idempotency_key.to_s
        )
      end

      def reload_generation(generation)
        Ticketing::CredentialGeneration.includes(credentials: :admission_slot).find(generation.id)
      end

      def invalid_idempotency_key
        replacement_error(:invalid_idempotency_key, "invalid_idempotency_key", :unprocessable_entity)
      end

      def replacement_error(key, code, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.package_issuance.errors.#{key}"), code:, status:, errors:
        )
      end
    end
  end
end
