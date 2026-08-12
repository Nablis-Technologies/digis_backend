# frozen_string_literal: true

module Admin
  module Commercial
    # Runs and inspects immutable, digest-bound commercial simulation evidence.
    class SimulationsController < ApplicationController
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present, only: :create
      before_action :find_simulation, only: :show

      def index
        authorize ::Commercial::Simulation.new
        simulations = policy_scope(::Commercial::Simulation).includes(:fee_schedule_version, :assignment)
        render_success(data: simulations, serializer_options: { serializer: ::Commercial::SimulationSerializer })
      end

      def show
        authorize @simulation
        render_success(data: @simulation, serializer_options: { serializer: ::Commercial::SimulationSerializer })
      end

      def create
        version = ::Commercial::FeeScheduleVersion.find(simulation_params[:fee_schedule_version_id])
        assignment = simulation_params[:assignment_id].present? ? ::Commercial::Assignment.find(simulation_params[:assignment_id]) : nil
        authorize ::Commercial::Simulation.new(fee_schedule_version: version, assignment:)
        result = ::Commercial::Simulations::Run.call(
          version:, assignment:, actor: current_user,
          scenario: simulation_params[:scenario] || {}, idempotency_key:
        )
        render_service_result(result, success_status: :created,
          serializer_options: { serializer: ::Commercial::SimulationSerializer })
      end

      private

      def find_simulation
        @simulation = policy_scope(::Commercial::Simulation).includes(:fee_schedule_version, :assignment).find(params[:id])
      end

      def simulation_params
        raw = params.require(:simulation).permit(:fee_schedule_version_id, :assignment_id, scenario: {})
        raw[:scenario] = raw[:scenario].to_unsafe_h if raw[:scenario].respond_to?(:to_unsafe_h)
        raw
      end
    end
  end
end
