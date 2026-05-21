module Core
  class AuthController < Core::ApplicationController
    skip_before_action :authenticate_user, only: %i[login signup refresh]
    skip_before_action :authorize_action!, only: %i[login signup refresh]

    def login
      skip_authorization
      auth_result = Core::AuthService.call(
        operation: :authenticate_user,
        identifier: identifier_param,
        password: params[:password]
      )
      user = auth_result.value

      if auth_result.success? && user&.valid_for_authentication?
        tokens = sign_in(user, request)
        render_success(
          "Login successful",
          data: {
            user: user,
            access_token: tokens[:access_token],
            refresh_token: tokens[:refresh_token]
          },
          serializer_options: {
            user: { serializer: Core::UserAuthSerializer }
          }
        )
      else
        render_error("Invalid credentials", status: :unauthorized, code: "invalid_credentials")
      end
    end

    def signup
      skip_authorization
      user = Core::User.new(user_params)
      begin
        ActiveRecord::Base.transaction do
          user.save!
          assign_default_role(user)
        end

        render_success(
          "Signup successful",
          data: {
            user: user.reload
          },
          status: :created,
          serializer_options: {
            user: { serializer: Core::UserAuthSerializer }
          }
        )
      rescue ActiveRecord::RecordInvalid => e
        render_error(
          "Signup failed",
          errors: e.record.errors.full_messages,
          status: :unprocessable_entity,
          code: "signup_failed"
        )
      rescue StandardError => e
        Rails.logger.error "Signup error: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}" if defined?(Rails)
        render_error(
          "Signup failed",
          errors: [ e.message.to_s ],
          status: :internal_server_error,
          code: "signup_failed"
        )
      end
    end

    def logout
      sign_out
      render_success("Logout successful")
    end

    def me
      skip_authorization
      render_success(
        "Current user fetched successfully",
        data: {
          user: current_user
        },
        serializer_options: {
          user: { serializer: Core::UserAuthSerializer }
        }
      )
    end

    def refresh
      skip_authorization
      new_tokens = refresh_token

      if new_tokens
        render_success(
          "Token refreshed successfully",
          data: {
            access_token: new_tokens[:access_token],
            refresh_token: new_tokens[:refresh_token],
            user: new_tokens[:user]
          },
          serializer_options: {
            user: { serializer: Core::UserAuthSerializer }
          }
        )
      else
        render_error("Invalid token", status: :unauthorized, code: "invalid_token")
      end
    end

    private

    def user_params
      params.require(:user).permit(
        :email,
        :phone,
        :password,
        :password_confirmation
      )
    end

    def identifier_param
      params[:identifier].presence || params[:email_or_phone]
    end

    def assign_default_role(user)
      role = Core::Role.find_or_create_by!(code: "USER") do |record|
        record.name = "User"
        record.description = "Default end-user role"
        record.active = true
      end

      Core::UserRole.find_or_create_by!(user: user, role: role)
    end
  end
end
