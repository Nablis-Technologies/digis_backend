# frozen_string_literal: true

module Admin
  module Commercial
    # Coordinates authorization and parameter normalization for fee-version
    # authoring and lifecycle commands; state transitions remain in services.
    class FeeScheduleVersionsController < ApplicationController
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present,
        only: %i[create update simulate submit approve reject schedule activate terminate deliver_notice]
      before_action :find_version, only: %i[show update simulate submit approve reject schedule activate terminate deliver_notice]

      def index
        versions = policy_scope(::Commercial::FeeScheduleVersion)
        versions = versions.where(fee_schedule_id: params[:fee_schedule_id]) if params[:fee_schedule_id].present?
        authorize ::Commercial::FeeScheduleVersion.new
        render_success(data: versions.includes(
          { fee_components: %i[fee_amounts fee_tiers] }, :assignments, :simulations
        ))
      end

      def show
        authorize @version
        render_version(@version)
      end

      def create
        schedule = ::Commercial::FeeSchedule.find(params[:fee_schedule_id] || params[:fee_schedule_version].try(:[], :fee_schedule_id))
        version = schedule.fee_schedule_versions.new
        authorize version
        result = ::Commercial::Admin::UpsertVersion.call(
          version:, fee_schedule: schedule, actor: current_user,
          attributes: version_params, idempotency_key:, create: true
        )
        render_service_result(result, success_status: :created, serializer_options: version_serializer_options)
      end

      def update
        authorize @version
        result = ::Commercial::Admin::UpsertVersion.call(
          version: @version, fee_schedule: @version.fee_schedule, actor: current_user,
          attributes: version_params, idempotency_key:, create: false
        )
        render_service_result(result, serializer_options: version_serializer_options)
      end

      def simulate
        authorize @version, :simulate?
        assignment = assignment_from_params
        result = ::Commercial::Simulations::Run.call(
          version: @version, assignment:, actor: current_user,
          scenario: scenario_params, idempotency_key:
        )
        render_service_result(result, serializer_options: { serializer: ::Commercial::SimulationSerializer })
      end

      def submit
        authorize @version, :submit?
        result = ::Commercial::Versions::Submit.call(version: @version, actor: current_user, idempotency_key:)
        render_service_result(result, serializer_options: version_serializer_options)
      end

      def approve
        authorize @version, :approve?
        result = ::Commercial::Versions::Approve.call(
          version: @version, actor: current_user, reason: transition_params[:reason],
          break_glass: transition_params[:break_glass], idempotency_key:
        )
        render_service_result(result, serializer_options: version_serializer_options)
      end

      def reject
        authorize @version, :reject?
        result = ::Commercial::Versions::Reject.call(
          version: @version, actor: current_user, reason: transition_params[:reason], idempotency_key:
        )
        render_service_result(result, serializer_options: version_serializer_options)
      end

      def schedule
        authorize @version, :schedule?
        result = ::Commercial::Versions::Schedule.call(
          version: @version, actor: current_user, reason: transition_params[:reason],
          break_glass: transition_params[:break_glass], idempotency_key:
        )
        render_service_result(result, serializer_options: version_serializer_options)
      end

      def activate
        authorize @version, :activate?
        result = ::Commercial::Versions::Activate.call(
          version: @version, actor: current_user, reason: transition_params[:reason],
          break_glass: transition_params[:break_glass], idempotency_key:
        )
        render_service_result(result, serializer_options: version_serializer_options)
      end

      def terminate
        authorize @version, :terminate?
        result = ::Commercial::Versions::Terminate.call(
          version: @version, actor: current_user, reason: transition_params[:reason], idempotency_key:
        )
        render_service_result(result, serializer_options: version_serializer_options)
      end

      def deliver_notice
        authorize @version, :deliver_notice?
        organization = ::Organizations::Organization.find(notice_params[:organization_id])
        result = ::Commercial::Defaults::DeliverTermNotice.call(
          organization:, version: @version, actor: current_user,
          delivery_method: notice_params[:delivery_method] || "in_app", idempotency_key:
        )
        render_service_result(result, serializer_options: { serializer: ::Commercial::TermNoticeSerializer })
      end

      private

      def find_version
        relation = policy_scope(::Commercial::FeeScheduleVersion)
        relation = relation.where(fee_schedule_id: params[:fee_schedule_id]) if params[:fee_schedule_id].present?
        @version = relation.includes(
          { fee_components: %i[fee_amounts fee_tiers] }, :assignments, :simulations
        ).find(params[:id])
      end

      def version_params
        params.require(:fee_schedule_version).permit(
          :supersedes_version_id, :acceptance_policy, :grandfather_until,
          :effective_from, :effective_until, :legal_document_version_id,
          components: [
            :component_type, :calculation_type, :charged_to, :organizer_payer_choice,
            :funded_by, :basis_type, :rate_bps, :refund_policy, :offset_component_type,
            :event_product_id, :product_type, :sale_context, :provider, :payment_method,
            :sales_channel, :currency, :label,
            { amounts: %i[currency fixed_amount_minor minimum_minor maximum_minor],
              tiers: %i[position metric_type window_type currency starts_at_value rate_bps fixed_amount_minor minimum_minor maximum_minor] }
          ]
        )
      end

      def scenario_params
        params[:scenario].present? ? params[:scenario].to_unsafe_h : {}
      end

      def assignment_from_params
        id = params[:assignment_id] || params.dig(:simulation, :assignment_id)
        return if id.blank?

        ::Commercial::Assignment.find(id)
      end

      def transition_params
        permitted = params.permit(:reason, :break_glass)
        permitted[:break_glass] = ActiveModel::Type::Boolean.new.cast(permitted[:break_glass])
        permitted
      end

      def notice_params
        params.permit(:organization_id, :delivery_method)
      end

      def version_serializer_options
        { serializer: ::Commercial::FeeScheduleVersionSerializer,
          include: %i[fee_components assignments simulations] }
      end

      def render_version(version)
        render_success(data: version, serializer_options: version_serializer_options)
      end
    end
  end
end
