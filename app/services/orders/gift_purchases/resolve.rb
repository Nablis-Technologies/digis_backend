# frozen_string_literal: true

module Orders
  module GiftPurchases
    # Resolves a bearer gift capability to the recipient-only experience. The
    # token is verified from the request body and never appears in the result.
    class Resolve < Core::BaseService
      View = Data.define(:gift, :event, :product, :forms, :consents, :ticket, :pending_consents)

      def initialize(gift_purchase_id:, token:, actor: nil, at: Time.current)
        @gift_purchase_id = gift_purchase_id
        @token = token.to_s
        @actor = actor
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(error(:gift_invalid, :not_found)) if @initialization_error || @token.blank?

        gift = load_gift
        return failure(error(:gift_invalid, :not_found)) unless token_matches?(gift)

        invalid = validate(gift)
        return failure(invalid) if invalid

        form_versions = Ticketing::Forms::ApplicableSchema.call(
          event: gift.order_item.order.event,
          ticket_type: gift.order_item.event_product.ticket_type
        )
        return failure(form_versions.error) if form_versions.failure?

        ticket = ticket_projection(gift)
        return failure(error(:gift_claim_failed, :conflict)) if gift.status == "claimed" && ticket.nil?

        success(View.new(
          gift: gift_projection(gift),
          event: event_projection(gift.order_item.order.event),
          product: product_projection(gift.order_item.event_product),
          forms: form_projections(form_versions.value),
          consents: consent_projections(gift.order_item.order.event, gift.order_item.event_product.ticket_type),
          ticket:,
          pending_consents: pending_consent_projections(gift)
        ))
      rescue ActiveRecord::RecordNotFound
        failure(error(:gift_invalid, :not_found))
      end

      private

      def load_gift
        Orders::GiftPurchase.includes(
          :recipient_user,
          order_item: [
            { registration: :consent_requirements },
            { event_product: :ticket_type },
            { order: :event }
          ]
        ).find(@gift_purchase_id)
      end

      def token_matches?(gift)
        expected = Orders::GiftPurchase.token_digest_for(token: @token)
        ActiveSupport::SecurityUtils.secure_compare(gift.token_digest, expected)
      end

      def validate(gift)
        return error(:gift_revoked, :gone) if gift.status == "revoked"
        return error(:gift_expired, :gone) if gift.status == "expired" || gift.expires_at <= @at
        return error(:gift_not_ready, :conflict) unless gift.status.in?(%w[ready pending_recipient_consent claimed])

        item = gift.order_item
        order = item.order
        return error(:gift_not_ready, :conflict) unless order.status == "fulfilled" && order.paid? && item.fulfilled?
        return error(:event_cancelled, :gone) if order.event.status == "cancelled"
        return error(:gift_recipient_mismatch, :forbidden) if @actor && @actor.id != gift.recipient_user_id
        registration = item.registration
        return error(:gift_not_ready, :conflict) unless registration&.user_id == gift.recipient_user_id
        return error(:gift_not_ready, :conflict) if registration.status.in?(%w[cancelled expired rejected])
        return error(:gift_not_ready, :conflict) if item.fulfillment_status.in?(%w[cancelled refunded])

        nil
      end

      def gift_projection(gift)
        {
          id: gift.id,
          status: gift.status,
          expires_at: gift.expires_at,
          note: gift.note
        }
      end

      def event_projection(event)
        { id: event.id, slug: event.slug, title: event.title }
      end

      def product_projection(product)
        {
          id: product.id,
          name: product.name,
          description: product.description,
          admissions_per_unit: product.ticket_type.admissions_per_unit
        }
      end

      def form_projections(versions)
        versions.map do |version|
          {
            id: version.id,
            registration_form_id: version.registration_form_id,
            name: version.registration_form.name,
            version: version.version,
            questions: version.questions.sort_by(&:position).map do |question|
              {
                id: question.id,
                key: question.key,
                type: question.type,
                response_scope: question.response_scope,
                label: question.label,
                required: question.required,
                options: question.options,
                validation_rules: question.validation_rules
              }
            end
          }
        end
      end

      def consent_projections(event, ticket_type)
        documents = Events::ConsentDocument.where(event_id: event.id, active: true)
          .includes(:versions, :consent_document_products).to_a
        versions = Events::ConsentDocumentVersion.where(
          consent_document_id: documents.map(&:id), status: "published"
        ).includes(consent_document: %i[versions consent_document_products]).to_a

        versions.select do |version|
          document = version.consent_document
          published_versions = document.versions.select(&:published?)
          current = published_versions.one? && published_versions.first.id == version.id
          products = document.consent_document_products
          current && (products.empty? || products.any? { |row| row.ticket_type_id == ticket_type.id })
        end.map do |version|
          {
            id: version.id,
            version: version.version,
            title: version.title,
            body: version.body,
            content_sha256: version.content_sha256,
            required: version.required,
            acceptance_scope: version.acceptance_scope
          }
        end
      end

      def ticket_projection(gift)
        return unless gift.status.in?(%w[claimed pending_recipient_consent])

        ticket = Ticketing::Ticket.includes(
          :event,
          :event_product,
          current_credential_generation: :credentials
        )
          .find_by(order_item_id: gift.order_item_id, unit_number: 1)
        return unless ticket

        credential = ticket.current_credential_generation&.credentials&.first
        active = credential&.status == "active"
        {
          id: ticket.id,
          status: ticket.status,
          event_id: ticket.event_id,
          event_title: ticket.event.title,
          product_id: ticket.event_product_id,
          product_name: ticket.event_product.name,
          credential_status: credential&.status,
          qr_token: active ? credential.qr_token : nil,
          lookup_code: active ? credential.lookup_code : nil
        }
      end

      def pending_consent_projections(gift)
        registration = gift.order_item&.registration
        return [] unless registration

        requirements = registration.association(:consent_requirements).loaded? ?
          registration.consent_requirements.select(&:pending?) :
          registration.consent_requirements.where(status: "pending").to_a

        requirements.sort_by { |r| [ r.package_unit_number || 0, r.admission_position || 0, r.id ] }.map do |requirement|
          {
            id: requirement.id,
            consent_document_version_id: requirement.consent_document_version_id,
            acceptance_scope: requirement.acceptance_scope,
            package_unit_number: requirement.package_unit_number,
            admission_position: requirement.admission_position,
            required: requirement.required
          }
        end
      end

      def error(key, status)
        code = key.to_s
        Core::BusinessError.new(
          I18n.t("orders.gift_purchases.errors.#{code}"),
          code:,
          status:
        )
      end
    end
  end
end
