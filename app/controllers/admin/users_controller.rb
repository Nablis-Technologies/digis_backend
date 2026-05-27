module Admin
  class UsersController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Core::User
    self.resource_param = :id

    auditable_model Core::User
    auditable on: %i[create update destroy deactivate reactivate],
              action: { deactivate: "update", reactivate: "update" }

    before_action :set_user, only: %i[deactivate reactivate]

    def index
      authorize Core::User.new, :index?
      users = policy_scope(Core::User)
      users = Core::User.active unless ActiveModel::Type::Boolean.new.cast(params[:include_deactivated])
      users = users.includes(eager_loaded_associations)
      users = filter_records(users)
      users = apply_ordering(users)

      total_count = users.count if paginated_request?
      users = apply_pagination(users) if paginated_request?

      render_success(data: users, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] }, pagination: paginated_request? ? pagination_metadata(total_count) : nil)
    end

    def show
      authorize @obj

      render_success(data: @obj, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] })
    end

    def create
      object = Core::User.new(model_params)
      authorize object

      ActiveRecord::Base.transaction do
        object.save!
        @obj = object

        render_success(data: @obj, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] }, status: :created)
      end
    rescue ActiveRecord::RecordInvalid => error
      render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
    end

    def update
      authorize @obj

      ActiveRecord::Base.transaction do
        @obj.update!(model_params)
        render_success(data: @obj, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] })
      end
    rescue ActiveRecord::RecordInvalid => error
      render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
    end

    def deactivate
      authorize @obj

      raise Core::AuthenticationError.new("Cannot deactivate yourself", code: "self_deactivation") if @obj == current_user

      ActiveRecord::Base.transaction do
        @obj.update!(deactivated_at: Time.current, deactivated_reason: params[:deactivated_reason])
        Core::AuthService.call(operation: :revoke_all_user_tokens, user: @obj)
        render_success(data: @obj, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] })
      end
    end

    def reactivate
      authorize @obj

      ActiveRecord::Base.transaction do
        @obj.update!(deactivated_at: nil, deactivated_reason: nil)
        render_success(data: @obj, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] })
      end
    end

    private

    def set_user
      @obj = Core::User.find(params[:id])
    end

    def model_params
      params.require(:user).permit(:email, :phone, :password, :verified_at)
    end

    def allowed_order_columns
      %w[id email phone verified_at deactivated_at created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id email phone verified_at deactivated_at deactivated_reason], include: %i[roles] },
        show: { fields: %i[id email phone verified_at deactivated_at deactivated_reason created_at updated_at], include: %i[roles] },
        create: { fields: %i[id email phone verified_at], include: %i[roles] },
        update: { fields: %i[id email phone verified_at], include: %i[roles] }
      }
    end
  end
end
