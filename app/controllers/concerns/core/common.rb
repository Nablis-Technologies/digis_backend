module Core
  module Common
    extend ActiveSupport::Concern
    include Core::Filterable
    include Core::JsonResponse
    include Core::Pagination

    included do
      class_attribute :model_class, default: nil
      before_action :set_clazz
      before_action :set_object, only: %i[show update destroy]
    end

    def index
      authorize @clazz.new, :index?

      data, serializer_options = resolve_block_result(default: policy_scope(@clazz))
      data = data.includes(eager_loaded_associations) if eager_loaded_associations.present?
      data = filter_records(data)
      data = apply_ordering(data)

      total_count = data.count if paginated_request?
      data = apply_pagination(data) if paginated_request?

      includes = serializer_includes_for_action(:index)
      serializer_options[:include] = includes if includes.present?

      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(data: data, serializer_options: serializer_options, pagination: pagination)
    end

    def show
      authorize @obj

      data, serializer_options = resolve_block_result(default: @obj)
      data = @clazz.includes(eager_loaded_associations).find(data.id) if data.is_a?(@clazz) && eager_loaded_associations.present?

      includes = serializer_includes_for_action(:show)
      serializer_options[:include] = includes if includes.present?

      render_success(data: data, serializer_options: serializer_options)
    end

    def create
      authorize @clazz.new, :create?

      object, serializer_options = resolve_block_result(default: @clazz.new(model_params))

      ActiveRecord::Base.transaction do
        if object.save
          @obj = object
          after_save_hook(object) if respond_to?(:after_save_hook, true)

          object = @clazz.includes(eager_loaded_associations).find(object.id) if eager_loaded_associations.present?
          @obj = object

          includes = serializer_includes_for_action(:create)
          serializer_options[:include] = includes if includes.present?

          render_success(data: object, serializer_options: serializer_options, status: :created)
        else
          render_error(errors: object.errors, status: :unprocessable_entity)
        end
      end
    rescue ActiveRecord::RecordInvalid => error
      render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound => error
      render_error(error.message, status: :not_found)
    rescue Pundit::NotAuthorizedError
      raise
    end

    def update
      authorize @obj

      object, serializer_options = resolve_block_result(default: @obj)

      ActiveRecord::Base.transaction do
        if object.update(model_params)
          after_save_hook(object) if respond_to?(:after_save_hook, true)

          object = @clazz.includes(eager_loaded_associations).find(object.id) if eager_loaded_associations.present?
          @obj = object

          includes = serializer_includes_for_action(:update)
          serializer_options[:include] = includes if includes.present?

          render_success(data: object, serializer_options: serializer_options)
        else
          render_error(errors: object.errors, status: :unprocessable_entity)
        end
      end
    rescue ActiveRecord::RecordInvalid => error
      render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound => error
      render_error(error.message, status: :not_found)
    rescue Pundit::NotAuthorizedError
      raise
    end

    def destroy
      authorize @obj
      if @obj.respond_to?(:soft_delete)
        @obj.soft_delete!
      else
        @obj.destroy!
      end
      render_success(status: :ok)
    end

    private

    def set_clazz
      @clazz = self.class.model_class
      return if @clazz.present?

      raise ArgumentError, "#{self.class.name} must declare self.model_class"
    end

    def set_object
      @obj = if eager_loaded_associations.present?
               @clazz.includes(eager_loaded_associations).find(params[:id])
      else
               @clazz.find(params[:id])
      end
    end

    def resolve_block_result(default:)
      return [ default, {} ] unless block_given?

      incoming = yield

      if incoming.is_a?(Array)
        [ incoming[0], incoming[1] || {} ]
      elsif incoming.is_a?(Hash)
        [ default, incoming ]
      else
        [ incoming, {} ]
      end
    end

    def eager_loaded_associations
      []
    end

    def allowed_order_columns
      %w[id created_at updated_at]
    end

    def default_serializer_includes
      {}
    end

    def serializer_includes_for_action(action)
      includes = default_serializer_includes
      return includes if includes.is_a?(Array)
      return [] unless includes.is_a?(Hash)

      includes[action] || includes[:default] || []
    end

    def model_params
      raise NotImplementedError, "#{self.class.name} must implement #model_params"
    end
  end
end
