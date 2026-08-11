module Organizations
  class VerificationsController < Organizations::ApplicationController
    include Core::JsonResponse

    class InvalidTransition < StandardError; end

    rescue_from InvalidTransition, with: :handle_invalid_transition
    rescue_from Pundit::NotAuthorizedError, with: :handle_not_authorized
    rescue_from ActiveRecord::RecordInvalid, with: :handle_record_invalid

    before_action :set_organization
    before_action :authorize_review_action!, only: %i[submit approve reject request_modification resubmit]

    AUTO_APPROVE_AUDIENCE = %w[under_100 100_500].freeze

    def submit
      ensure!(submission_ready?, I18n.t("review.errors.documents_required"))
      ensure_not_already_submitted!

      status = auto_approve? ? "approved" : "pending"
      reviewer = auto_approve? ? nil : current_user

      review = create_review_transition!(status, from: "draft", reviewer: reviewer, feedback: {})
      record_audit!(review)
      render_success(data: @organization)
    end

    def approve
      review = create_review_transition!("approved", from: "pending", reviewer: current_user, feedback: {})
      record_audit!(review)
      render_success(data: @organization)
    end

    def reject
      ensure!(review_feedback_params.present?, I18n.t("review.errors.feedback_required_generic"))
      review = create_review_transition!("rejected", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)
      render_success(data: @organization)
    end

    def request_modification
      ensure!(review_feedback_params.present?, I18n.t("review.errors.feedback_required_generic"))
      review = create_review_transition!("modify", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)
      render_success(data: @organization)
    end

    def resubmit
      @organization.update!(model_params) if model_params.present?
      review = create_review_transition!("pending", from: %w[rejected modify], reviewer: current_user, feedback: {})
      record_audit!(review)
      render_success(data: @organization)
    end

    private

    def create_review_transition!(status, from:, reviewer:, feedback:)
      current_review = @organization.current_review_for(:verification)
      current_status = current_review&.status || "draft"

      ensure!(
        Array(from).include?(current_status),
        I18n.t(
          "review.errors.invalid_transition",
          from_status: current_status,
          to_status: status
        )
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

    def ensure_not_already_submitted!
      ensure!(
        @organization.current_review_for(:verification).nil?,
        I18n.t("review.errors.already_submitted")
      )
    end

    def ensure!(condition, message)
      raise InvalidTransition, message unless condition
    end

    def submission_ready?
      @organization.profile.attached? &&
        @organization.banner.attached? &&
        @organization.business_license.attached? &&
        @organization.tin_certificate.attached?
    end

    def auto_approve?
      @organization.estimated_audience.in?(AUTO_APPROVE_AUDIENCE)
    end

    def authorize_review_action!
      authorize @organization, policy_class: Organizations::VerificationPolicy
      raise Pundit::NotAuthorizedError,
        I18n.t("review.errors.not_allowed_organization", action: action_name) unless valid_reviewer?
    end

    def valid_reviewer?
      return false if owner_enforcement_failed?
      return false if self_review?
      true
    end

    def owner_enforcement_failed?
      return false if current_user.super_admin?

      membership = @organization.memberships.active.find_by(user_id: current_user.id)
      return true if membership.nil?

      %w[submit resubmit].include?(action_name) && membership.staff?
    end

    def self_review?
      return false unless %w[approve reject request_modification].include?(action_name)

      @organization.memberships.active.exists?(user_id: current_user.id)
    end

    def record_audit!(review)
      return if review.reviewed_by.nil? && review.status == "approved"

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

    def handle_record_invalid(exception)
      render_error(exception.record.errors.full_messages.first, status: :unprocessable_entity)
    end

    def set_organization
      @clazz = Organizations::Organization
      @organization = Organizations::Organization.find(params[:organization_id])
    rescue ActiveRecord::RecordNotFound
      render_error(:"organization.errors.not_found", status: :not_found)
    end

    def model_params
      return {} unless params[:organization].present?

      params.require(:organization).permit(
        :name, :description, :organizer_type, :category,
        :contact_phone, :contact_email, :website_url,
        :tin_number, :address_line1, :address_line2, :city, :region,
        :estimated_audience, :event_frequency,
        social_links: {}
      )
    end

    def review_feedback_params
      feedback = params[:feedback] || params[:review_feedback]
      return {} unless feedback

      feedback.permit! if feedback.respond_to?(:permit!)
      feedback
    end
  end
end
