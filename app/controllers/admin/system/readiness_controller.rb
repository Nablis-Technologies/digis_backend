# frozen_string_literal: true

module Admin
  module System
    # Authenticated platform-admin endpoint for bounded local dependency
    # readiness. Process liveness remains available through `/up`.
    class ReadinessController < Admin::ApplicationController
      include Core::CommandResponse

      def show
        authorize [ :admin, :system, :readiness ], :show?,
          policy_class: Admin::System::ReadinessPolicy
        render_service_result(Admin::System::Readiness.call)
      end
    end
  end
end
