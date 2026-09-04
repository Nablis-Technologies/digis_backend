# frozen_string_literal: true

module Admin
  module Messaging
    # Admin lifecycle API for draft, active, and retired credit-rate versions.
    # Mutations require idempotency keys; the commands own overlap and audit
    # invariants while this controller owns authorization and serialization.
    class CreditRatesController < Admin::ApplicationController
      include Core::Pagination
      include Core::Filterable
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present, only: %i[create activate retire]
      before_action :set_rate, only: %i[show activate retire]

      def index
        authorize ::Messaging::CreditRateVersion, :index?
        rates = ::Messaging::CreditRateVersion.all.includes(:organization)
        rates = filter_records(rates)
        rates = apply_ordering(rates)
        total_count = rates.count if paginated_request?
        rates = paginated_request? ? apply_pagination(rates) : rates.limit(default_per_page)
        render_success(
          data: rates,
          serializer_options: { serializer: ::Messaging::CreditRateVersionSerializer },
          pagination: paginated_request? ? pagination_metadata(total_count) : nil
        )
      end

      def show
        authorize @rate, :show?
        render_success(data: @rate, serializer_options: { serializer: ::Messaging::CreditRateVersionSerializer })
      end

      def create
        authorize ::Messaging::CreditRateVersion.new, :create?
        result = ::Messaging::CreditRates::Create.call(
          actor: current_user, attributes: rate_params, idempotency_key:
        )
        render_service_result(result, success_status: :created,
          serializer_options: { serializer: ::Messaging::CreditRateVersionSerializer })
      end

      def activate
        authorize @rate, :activate?
        result = ::Messaging::CreditRates::Activate.call(rate: @rate, actor: current_user, idempotency_key:)
        render_service_result(result, serializer_options: { serializer: ::Messaging::CreditRateVersionSerializer })
      end

      def retire
        authorize @rate, :retire?
        result = ::Messaging::CreditRates::Retire.call(rate: @rate, actor: current_user, idempotency_key:)
        render_service_result(result, serializer_options: { serializer: ::Messaging::CreditRateVersionSerializer })
      end

      private

      def set_rate
        @rate = ::Messaging::CreditRateVersion.find(params[:id])
      end

      def rate_params
        params.require(:credit_rate_version).permit(
          :organization_id, :channel, :version, :currency, :unit_price_minor,
          :provider_cost_minor, :country_code, :effective_from, :effective_until,
          volume_tiers: %i[from to unit_price_minor]
        ).to_h
      end

      def allowed_order_columns
        %w[id channel version currency country_code effective_from effective_until status created_at]
      end
    end
  end
end
