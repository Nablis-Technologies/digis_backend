# frozen_string_literal: true

module Marketplace
  # Buyer checkout boundary for one active listing. ReserveListing owns the
  # seller suspension, buyer registration, commercial snapshot, and hold;
  # this controller only authorizes and forwards the request.
  class ResalePurchasesController < Marketplace::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :load_listing

    def create
      authorize @listing, :purchase?, policy_class: ResaleListingPolicy unless replayable_purchase?
      result = ReserveListing.call(
        listing: @listing,
        buyer: current_user,
        idempotency_key:,
        answers: normalized_answers,
        consents: normalized_consents
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Orders::OrderSerializer }
      )
    end

    private

    def load_listing
      @listing = ResaleListing.includes(commercial_fee_component: :fee_schedule_version).find(params[:resale_listing_id])
    end

    def replayable_purchase?
      ReserveListing.replayable?(listing: @listing, buyer: current_user, idempotency_key:)
    end

    def normalized_answers
      raw = params.dig(:purchase, :answers) || params[:answers]
      normalize_submission_collection(raw, %w[
        form_version_id question_key package_unit_number admission_position value
      ])
    end

    def normalized_consents
      raw = params.dig(:purchase, :consents) || params[:consents]
      normalize_submission_collection(raw, %w[
        consent_document_version_id request_uuid acceptance_method content_sha256
        package_unit_number admission_position idempotency_key
      ])
    end

    def normalize_submission_collection(raw, allowed_keys)
      return [] if raw.nil?
      return raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h) && !raw.is_a?(Array)
      return raw if raw.is_a?(Hash)

      if raw.is_a?(Array)
        raw.filter_map do |entry|
          attrs = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
          next unless attrs.is_a?(Hash)

          attrs.slice(*allowed_keys, *allowed_keys.map(&:to_sym)).symbolize_keys
        end
      else
        []
      end
    end
  end
end
