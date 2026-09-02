# frozen_string_literal: true

module Catalog
  # Product lifecycle endpoints — create draft, update, destroy, activate,
  # deactivate. Nested under events for authorization scoping.
  class EventProductsController < Catalog::ApplicationController
    include Core::Common

    PRODUCT_FIELDS = %i[
      id event_id name description type status inventory_mode allow_custom_price
      sales_start_at sales_end_at min_per_order max_per_order
      schedule_change_refund_policy sort_order metadata lock_version
      created_at updated_at ticket_type pricing product_accesses inventory
    ].freeze

    self.model_class = Catalog::EventProduct
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :event_products
    self.default_serializer = Catalog::Organizer::EventProductSerializer

    before_action :find_product, only: %i[activate deactivate update_inventory_configuration]
    before_action :ensure_idempotency_key_present, only: [ :create ]

    def create
      product = @parent.event_products.new
      authorize product, :create?

      outcome = Catalog::Products::CreateDraft.call(
        event: @parent,
        actor: current_user,
        product_attributes: product_creation_params,
        ticket_type_attributes: ticket_type_creation_params,
        price_attributes: price_creation_params,
        inventory_configuration: inventory_configuration_params,
        idempotency_key: idempotency_key
      )

      if outcome.success?
        render_success(data: reload_product_for_response(outcome.value), status: :created,
                       serializer_options: { include: renderable_associations })
      else
        render_error(outcome.error, status: :unprocessable_entity)
      end
    end

    def update
      authorize @obj
      return render_error(:"catalog.event_product.errors.active_immutable", status: :unprocessable_entity) if @obj.status == "active"
      return render_error(:"catalog.event_product.errors.retired_immutable", status: :unprocessable_entity) if @obj.status == "retired"

      permitted_updates = product_update_params
      previous_attributes = @obj.attributes.slice(*permitted_updates.keys.map(&:to_s))
      if ActiveRecord::Base.transaction do
        @obj.update(permitted_updates).tap do |updated|
          record_product_audit!("catalog.product.updated", previous_attributes) if updated
        end
      end
        render_success(data: reload_product_for_response(@obj), serializer_options: { include: renderable_associations })
      else
        render_error(@obj.errors.full_messages.join(", "), status: :unprocessable_entity)
      end
    end

    def destroy
      authorize @obj
      return render_error(:"catalog.event_product.errors.destroy_draft_required", status: :unprocessable_entity) unless @obj.status == "draft"
      return render_error(:"catalog.event_product.errors.inventory_activity_destroy_forbidden", status: :unprocessable_entity) if @obj.inventories.any? { |i| i.held_count.positive? || i.sold_count.positive? }

      ActiveRecord::Base.transaction do
        record_product_audit!("catalog.product.destroyed", @obj.attributes)
        @obj.destroy!
      end
      render_success(status: :ok)
    end

    def activate
      authorize @product, :activate?
      outcome = Catalog::Products::Activate.call(product: @product, actor: current_user)
      if outcome.success?
        render_success(data: reload_product_for_response(outcome.value),
                       serializer_options: { include: renderable_associations })
      else
        render_error(outcome.error, status: :unprocessable_entity)
      end
    end

    def deactivate
      authorize @product, :deactivate?
      outcome = Catalog::Products::Deactivate.call(product: @product, actor: current_user)
      if outcome.success?
        render_success(data: reload_product_for_response(outcome.value),
                       serializer_options: { include: renderable_associations })
      else
        render_error(outcome.error, status: :unprocessable_entity)
      end
    end

    def update_inventory_configuration
      authorize @product, :update?

      outcome = Catalog::Products::UpdateInventoryConfiguration.call(
        product: @product,
        actor: current_user,
        inventory_configuration: update_inventory_configuration_params
      )

      if outcome.success?
        render_success(data: reload_product_for_response(outcome.value),
                       serializer_options: { include: renderable_associations })
      else
        render_error(outcome.error, status: :unprocessable_entity)
      end
    end

    private

    def set_parent
      manageable_events = Events::AuthorizationResolver.manageable_catalog_events(current_user)
      @parent = manageable_events.find(params[:event_id])
    end

    def find_product
      @product = @parent.event_products.find(params[:id])
    end

    def reload_product_for_response(product)
      @obj = @clazz.includes(eager_loaded_associations).find(product.id)
    end

    def record_product_audit!(action, previous_attributes)
      auditable_attributes = previous_attributes.except("metadata")
      Core::Audit::Record.call(
        audit_key: "#{action.tr('.', '-')}-#{@obj.id}-#{@obj.lock_version}",
        action:,
        auditable_type: "Catalog::EventProduct",
        auditable_id: @obj.id,
        actor_type: current_user.class.name,
        actor_id: current_user.id,
        audited_changes: auditable_attributes.to_h do |name, previous|
          [ name, [ previous, @obj.attributes[name] ] ]
        end,
        metadata: { event_id: @obj.event_id }
      )
    end

    def product_creation_params
      params.permit(:name, :description, :type, :allow_custom_price,
                     :sales_start_at, :sales_end_at, :min_per_order, :max_per_order,
                     :schedule_change_refund_policy, :sort_order, :metadata)
    end

    def product_update_params
      params.permit(:name, :description, :allow_custom_price,
                     :sales_start_at, :sales_end_at, :min_per_order, :max_per_order,
                     :schedule_change_refund_policy, :sort_order, :metadata)
    end

    def ticket_type_creation_params
      return unless params.key?(:ticket_type_attributes)

      params.require(:ticket_type_attributes).permit(
        :approval_mode, :audience, :date_selection, :delegation_enabled,
        :delegation_validation_mode, :entry_validation_mode,
        :transferable, :transfer_cutoff_seconds_before_start,
        :admissions_per_unit, :resale_enabled, :resale_price_cap_type,
        :resale_fixed_cap_currency, :resale_fixed_cap_minor,
        :resale_percentage_cap_bps, :resale_cutoff_seconds_before_start,
        :max_completed_resales, :max_packages_per_user, :waitlist_enabled
      )
    end

    def price_creation_params
      return unless params.key?(:price_attributes)

      params.require(:price_attributes).permit(
        :type, :currency, :amount_minor, :ticket_type_id,
        :active_from, :active_to
      )
    end

    def inventory_configuration_params
      inv = params.require(:inventory_configuration)
      inv.permit(:mode, :capacity, dates: %i[event_date_id capacity])
    end

    def update_inventory_configuration_params
      inv = params.require(:inventory_configuration)
      inv.permit(:mode, :capacity, dates: %i[event_date_id capacity])
    end

    def model_params
      params.permit(:event_id)
    end

    def eager_load_config
      { default: [ :event, :ticket_type, :prices, :inventories,
                   { product_accesses: { event_date: :venue } } ] }
    end

    def allowed_order_columns
      %w[id name type status inventory_mode sort_order created_at]
    end

    def serializer_profile
      {
        index: { fields: PRODUCT_FIELDS, include: [] },
        show: { fields: PRODUCT_FIELDS, include: [] },
        create: { fields: PRODUCT_FIELDS, include: %i[ticket_type] },
        update: { fields: PRODUCT_FIELDS, include: %i[ticket_type] }
      }
    end
  end
end
