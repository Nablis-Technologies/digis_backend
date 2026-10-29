# frozen_string_literal: true

module Orders
  module AdmissionSelections
    # Submits/reuses registrations and transfers waitlist-offer holds. It runs
    # inside Create's transaction and never opens a separate commit boundary.
    class RegistrationAssembler < Core::BaseService
      Assembly = Data.define(:registrations_by_line_key, :gift_intents_by_line_key)

      class Abort < Core::Error
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def initialize(context:, products:)
        @context = context
        @products = products
      end

      def call
        registrations_by_line_key = {}
        gift_intents_by_line_key = {}
        context.items.each do |item|
          product = products.fetch(item.fetch(:event_product_id))
          next unless product.ticket?

          if item[:gift].present?
            gift = prepare_gift(item, product)
            registrations_by_line_key[item.line_key] = gift.registration
            gift_intents_by_line_key[item.line_key] = gift
          else
            registrations_by_line_key[item.line_key] = assemble(item, product)
          end
        end
        success(Assembly.new(registrations_by_line_key:, gift_intents_by_line_key:))
      rescue Abort => error
        failure(error.business_error)
      end

      private

      attr_reader :context, :products

      def assemble(item, product)
        registration = registration_for(item, product)
        registration.status == "offered" ? accept_offer(registration) : registration
      end

      def prepare_gift(item, product)
        if item.recipient_registration_data_present?
          abort_with(selection_error("admission_selection_invalid"))
        end

        result = Orders::GiftPurchases::Prepare.call(
          ticket_type: product.ticket_type,
          purchaser: context.buyer,
          recipient_phone: item[:gift][:recipient_phone],
          recipient_email: item[:gift][:recipient_email],
          note: item[:gift][:note],
          package_quantity: item[:quantity],
          selected_event_date_id: item[:selected_event_date_id],
          idempotency_key: registration_idempotency_key(product, item.line_key)
        )
        abort_with(result.error) if result.failure?

        result.value
      end

      def registration_for(item, product)
        item[:registration_id].present? ? existing_registration(item, product) : submit_registration(item, product)
      end

      def existing_registration(item, product)
        registration = Ticketing::Registration.lock.find(item[:registration_id])
        validate_existing_registration!(registration, item, product)
        registration
      rescue ActiveRecord::RecordNotFound
        abort_with(selection_error("registration_scope_invalid", status: :not_found))
      end

      def validate_existing_registration!(registration, item, product)
        valid_scope = registration.event_id == context.event.id &&
          registration.user_id == context.buyer.id && registration.ticket_type_id == product.ticket_type.id
        abort_with(selection_error("registration_scope_invalid", status: :forbidden)) unless valid_scope
        valid_request = registration.package_quantity == item[:quantity] &&
          (item[:selected_event_date_id].blank? || registration.selected_event_date_id.to_s == item[:selected_event_date_id])
        abort_with(selection_error("admission_selection_invalid")) unless valid_request
      end

      def submit_registration(item, product)
        result = Ticketing::Registrations::Submit.call(
          ticket_type: product.ticket_type,
          actor: context.actor,
          phone: context.phone.presence || context.buyer.phone,
          submission: submission(item),
          audience_proof: audience_proof(item[:audience_proof]),
          idempotency_key: registration_idempotency_key(product, item.line_key),
          guest: context.guest,
          phone_confirmation: context.guest && (context.phone_confirmation || context.guest_otp_verified),
          email: context.email,
          full_name: context.full_name
        )
        abort_with(result.error) if result.failure?

        result.value.registration
      end

      def submission(item)
        Ticketing::RegistrationSubmission.new(
          package_quantity: item[:quantity],
          selected_event_date_id: item[:selected_event_date_id],
          answers: item[:answers],
          consents: item[:consents]
        )
      end

      def accept_offer(registration)
        result = Ticketing::Waitlist::AcceptOffer.call(
          registration:,
          actor: context.actor,
          idempotency_key: waitlist_idempotency_key(registration),
          transfer_hold: true
        )
        abort_with(result.error) if result.failure?

        result.value
      end

      def audience_proof(proof)
        { access_code: proof[:access_code], invitation: proof[:invitation_token] || proof[:invitation] }
      end

      def registration_idempotency_key(product, line_key)
        Digest::SHA256.hexdigest(
          "admission-registration:#{context.event.id}:#{context.buyer.id}:#{context.idempotency_key.digest}:#{line_key}"
        )
      end

      def waitlist_idempotency_key(registration)
        Digest::SHA256.hexdigest(
          "admission-waitlist-accept:#{context.event.id}:#{context.buyer.id}:#{context.idempotency_key.digest}:#{registration.id}"
        )
      end

      def selection_error(code, status: :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("orders.checkout.errors.#{code}"),
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
