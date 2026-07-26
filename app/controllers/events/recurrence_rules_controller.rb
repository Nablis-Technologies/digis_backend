# frozen_string_literal: true

module Events
  class RecurrenceRulesController < Events::ApplicationController
    include Core::CommandResponse

    before_action :set_event
    before_action :set_rule, only: %i[update destroy activate deactivate]

    def show
      rule = @event.recurrence_rule
      authorize(rule || Events::RecurrenceRule.new(event: @event), :show?)
      render_success(:"events.recurrence.success.show", data: rule,
                     serializer_options: { serializer: Events::RecurrenceRuleSerializer })
    end

    def create
      authorize Events::RecurrenceRule.new(event: @event), :create?
      result = Events::Recurrence::Configure.call(
        event: @event, actor: current_user, attributes: rule_params
      )
      render_service_result(
        result,
        serializer_options: { serializer: Events::RecurrenceRuleSerializer },
        success_status: :created,
        message: :"events.recurrence.success.create"
      )
    end

    def update
      authorize @rule, :update?
      result = Events::Recurrence::Configure.call(
        event: @event, actor: current_user, attributes: rule_params
      )
      render_service_result(
        result,
        serializer_options: { serializer: Events::RecurrenceRuleSerializer },
        message: :"events.recurrence.success.update"
      )
    end

    def destroy
      authorize @rule, :destroy?
      record_audit
      @rule.destroy!
      render_success(:"events.recurrence.success.destroy", status: :ok)
    end

    def activate
      authorize @rule, :activate?
      result = Events::Recurrence::Activate.call(rule: @rule, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Events::RecurrenceRuleSerializer },
        message: :"events.recurrence.success.activate"
      )
    end

    def deactivate
      authorize @rule, :deactivate?
      result = Events::Recurrence::Deactivate.call(rule: @rule, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Events::RecurrenceRuleSerializer },
        message: :"events.recurrence.success.deactivate"
      )
    end

    private

    def record_audit
      Core::Audit::Record.call(
        audit_key: "event-recurrence-removed-#{@rule.id}",
        action: "event.recurrence.removed",
        auditable_type: "Events::RecurrenceRule",
        auditable_id: @rule.id,
        actor_type: current_user.class.name,
        actor_id: current_user.id,
        metadata: { event_id: @event.id }
      )
    end

    def set_event
      @event = Events::Event.find(params[:event_id])
    end

    def set_rule
      @rule = @event.recurrence_rule
      head :not_found unless @rule
    end

    def rule_params
      params.require(:recurrence_rule).permit(
        :rrule, :timezone, :dtstart_local, :duration_seconds,
        :generated_until, exdates: [], rdates: []
      )
    end
  end
end
