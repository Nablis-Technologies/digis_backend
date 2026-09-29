# frozen_string_literal: true

require "digest"

module Ticketing
  module Waitlist
    # Atomically creates or reuses an admission registration and enrolls it in
    # the per-offer FIFO only while the selected inventory is actually sold out.
    class Submit < Core::BaseService
      include Support

      Result = Data.define(:registration, :next_action)

      class Abort < StandardError
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def initialize(event:, ticket_type:, submission:, audience_proof: {}, idempotency_key:,
        actor: nil, guest: false, phone: nil, verification_token: nil, email: nil, full_name: nil)
        @event = event
        @ticket_type = ticket_type
        @submission = submission
        @audience_proof = audience_proof.to_h.symbolize_keys.slice(:access_code, :invitation, :invitation_token)
        @raw_idempotency_key = idempotency_key
        @actor = actor
        @guest = guest == true
        @phone = phone
        @verification_token = verification_token
        @email = email
        @full_name = full_name
      end

      def call
        @key = Core::IdempotencyKey.new(@raw_idempotency_key)
        buyer = resolve_buyer!
        outcome = nil
        Ticketing::Registration.transaction do
          lock_and_validate_offer!(buyer)
          registration = submit_registration(buyer)
          if registration.status == "pending_approval"
            outcome = Result.new(registration:, next_action: "awaiting_approval")
            next
          end

          queued = Enqueue.call(
            registration:,
            actor:,
            idempotency_key: child_key("enqueue", buyer)
          )
          abort_with(queued.error) if queued.failure?

          outcome = Result.new(registration: queued.value, next_action: "waitlisted")
        end
        success(outcome)
      rescue Abort => error
        failure(error.business_error)
      rescue ArgumentError => error
        failure(waitlist_error("invalid_idempotency_key", status: :bad_request, message: error.message))
      rescue ActiveRecord::RecordNotFound
        failure(waitlist_error("waitlist_product_not_found", status: :not_found))
      rescue ActiveRecord::RecordInvalid => error
        failure(Core::BusinessError.new(
          I18n.t("ticketing.registration_workflows.errors.invalid_registration"),
          code: "invalid_registration",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        ))
      end

      private

      attr_reader :event, :ticket_type, :submission, :actor, :audience_proof

      def resolve_buyer!
        return actor if !@guest && actor.is_a?(Core::User)
        abort_with(registration_error("phone_confirmation_required", status: :bad_request)) unless @guest && @phone.present?
        proof = verified_guest_proof
        abort_with(waitlist_error("phone_verification_required")) unless proof

        identity = Core::PhoneIdentity::ResolveGuest.call(phone: @phone)
        abort_with(identity.error) if identity.failure?
        user = identity.value.user
        abort_with(waitlist_error("phone_verification_required")) unless proof[:user_id].to_s == user.id.to_s
        user
      end

      def verified_guest_proof
        proof = Core::PhoneVerification::Verify.verify_proof(@verification_token)
        return unless proof && proof[:purpose] == "guest_admission"

        valid = Core::PhoneVerification::Verify.valid_proof?(
          token: @verification_token,
          phone: @phone,
          user_id: proof[:user_id],
          purpose: "guest_admission"
        )

        proof if valid
      end

      def lock_and_validate_offer!(buyer)
        locked_type = Ticketing::TicketType.lock
          .includes(event_product: [ :event, :product_accesses ])
          .find(ticket_type.id)
        locked_event = Events::Event.lock.find(event.id)
        product = Catalog::EventProduct.lock.find(locked_type.event_product_id)
        product.association(:ticket_type).target = locked_type
        product.association(:event).target = locked_event
        @locked_ticket_type = locked_type
        @locked_product = product
        abort_with(waitlist_error("event_cancelled", status: :conflict)) if locked_event.status == "cancelled"
        abort_with(waitlist_error("waitlist_product_not_found", status: :not_found)) unless
          Events::Event.publicly_visible.exists?(id: locked_event.id) &&
          product.event_id == locked_event.id && product.status == "active" && product.ticket?
        abort_with(waitlist_error("waitlist_disabled")) unless locked_type.waitlist_enabled?
        now = Time.current
        abort_with(waitlist_error("waitlist_product_unavailable")) if
          Catalog::Products::SalesWindow.error_key(product, at: now)
        validate_quantity!
        validate_selected_date!(product, locked_type)
        validate_sold_out!(product, locked_type)
        @buyer = buyer
      end

      def validate_quantity!
        quantity = submission.package_quantity
        abort_with(waitlist_error("quantity_invalid")) unless quantity.is_a?(Integer) && quantity.positive?
        abort_with(waitlist_error("quantity_outside_product_limit")) unless
          @locked_product.min_per_order <= quantity &&
          (@locked_product.max_per_order.nil? || quantity <= @locked_product.max_per_order)
      end

      def validate_selected_date!(product, locked_type)
        date_id = submission.selected_event_date_id
        if locked_type.date_selection == "choose_one"
          valid = date_id.present? && product.product_accesses.any? do |access|
            access.event_date_id.to_s == date_id.to_s && access.event_date&.status == "scheduled"
          end
          abort_with(waitlist_error("event_dates_required")) unless valid
        elsif date_id.present?
          abort_with(waitlist_error("registration_not_waitlistable"))
        end
      end

      def validate_sold_out!(product, locked_type)
        probe = Ticketing::Registration.new(
          event:,
          ticket_type: locked_type,
          selected_event_date_id: submission.selected_event_date_id,
          package_quantity: submission.package_quantity,
          admissions_per_unit_snapshot: locked_type.admissions_per_unit,
          party_size: submission.package_quantity * locked_type.admissions_per_unit
        )
        inventories = lock_product_inventories(product, probe)
        return if sold_out?(product, probe, inventories)

        abort_with(waitlist_error("waitlist_not_sold_out"))
      end

      def sold_out?(product, registration, inventories)
        return true unless inventory_fits?(product, registration, inventories)

        date_ids = registration.ticket_type.covered_date_ids(registration)
        dates = Events::EventDate.where(id: date_ids).order(:id).lock.to_a
        dates.any? do |date|
          date.venue_capacity.present? &&
            date.held_venue_count + date.issued_venue_count +
              registration.package_quantity * registration.admissions_per_unit_snapshot > date.venue_capacity
        end
      end

      def submit_registration(buyer)
        result = Ticketing::Registrations::Submit.call(
          ticket_type: @locked_ticket_type,
          actor: @guest ? nil : actor,
          phone: @guest ? @phone : buyer.phone,
          submission:,
          audience_proof: normalized_audience_proof,
          idempotency_key: child_key("registration", buyer),
          guest: @guest,
          phone_confirmation: @guest,
          email: @email,
          full_name: @full_name
        )
        abort_with(result.error) if result.failure?

        result.value.registration
      end

      def normalized_audience_proof
        {
          access_code: audience_proof[:access_code],
          invitation: audience_proof[:invitation_token] || audience_proof[:invitation]
        }
      end

      def child_key(purpose, buyer)
        Digest::SHA256.hexdigest(
          "ticketing-waitlist-#{purpose}:#{event.id}:#{buyer.id}:#{@key.digest}:#{ticket_type.event_product_id}"
        )
      end

      def waitlist_error(code, status: :unprocessable_entity, message: nil)
        Core::BusinessError.new(
          message || I18n.t("ticketing.registration_workflows.errors.#{code}"),
          code:,
          status:
        )
      end

      def registration_error(code, status: :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.#{code}"),
          code:,
          status:
        )
      end

      def abort_with(business_error)
        raise Abort, business_error
      end
    end
  end
end
