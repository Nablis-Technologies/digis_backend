module Admin
  class VerificationsController < Admin::ApplicationController
    include Core::JsonResponse

    class InvalidTransition < StandardError; end

    rescue_from InvalidTransition, with: :handle_invalid_transition
    rescue_from Pundit::NotAuthorizedError, with: :handle_not_authorized

    before_action :set_organization
    before_action :authorize_review_action!, only: %i[approve reject request_modification]

    def approve
      review = create_review_transition!("approved", from: "pending", reviewer: current_user, feedback: {})
      record_audit!(review)
      render_success(data: @organization)
    end

    def reject
      ensure!(review_feedback_params.present?, "Feedback is required")
      review = create_review_transition!("rejected", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)
      render_success(data: @organization)
    end

    def request_modification
      ensure!(review_feedback_params.present?, "Feedback is required")
      review = create_review_transition!("modify", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)
      render_success(data: @organization)
    end

    private

    def create_review_transition!(status, from:, reviewer:, feedback:)
      current_review = @organization.current_review_for(:verification)
      current_status = current_review&.status || "draft"

      ensure!(
        Array(from).include?(current_status),
        "Cannot transition from '#{current_status}' to '#{status}'"
      )

      review = current_review || @organization.build_review_for(:verification)
      review.update!(
        status: status,
        feedback: feedback,
        reviewed_by: reviewer,
        reviewed_at: Time.current
      )
      review
    end

    def ensure!(condition, message)
      raise InvalidTransition, message unless condition
    end

    def authorize_review_action!
      authorize @organization, policy_class: Admin::VerificationPolicy
      if @organization.memberships.active.exists?(user_id: current_user.id)
        raise Pundit::NotAuthorizedError, "cannot review your own organization"
      end
    end

    def record_audit!(review)
      @organization.record_audit!(
        action_name,
        actor: current_user,
        metadata: {
          "review_id"     => review.id,
          "review_status" => review.status,
          "feedback"      => review.feedback
        }.compact
      )
    end

    def handle_invalid_transition(exception)
      render_error(exception.message, status: :unprocessable_entity)
    end

    def handle_not_authorized(exception)
      render_error(exception.message, status: :forbidden)
    end

    def review_feedback_params
      feedback = params[:feedback] || params[:review_feedback]
      return {} unless feedback

      feedback.permit! if feedback.respond_to?(:permit!)
      feedback
    end

    def set_organization
      @clazz = Organizations::Organization
      @organization = Organizations::Organization.includes(
        :memberships, :reviews, :follows,
        { profile_attachment: :blob, banner_attachment: :blob,
          business_license_attachment: :blob, tin_certificate_attachment: :blob }
      ).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_error(:"organization.errors.not_found", status: :not_found)
    end
  end
end
