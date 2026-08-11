# frozen_string_literal: true

module Ticketing
  # Organizer endpoints for draft form schemas and their one-way publication.
  # Publishing requires an Idempotency-Key because it retires the prior live
  # version and writes audit evidence.
  class RegistrationFormVersionsController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::IdempotencyKeyResolver

    before_action :find_form
    before_action :find_version, only: %i[show publish]
    before_action :ensure_idempotency_key_present, only: :publish

    def index
      authorize @form.versions.new, :index?
      versions = @form.versions.includes(:questions).order(version: :desc)
      render_success(data: versions, serializer_options: serializer_options)
    end

    def show
      authorize @version
      render_success(data: @version, serializer_options: serializer_options)
    end

    def create
      version = @form.versions.new(version_attributes)
      authorize version
      unless valid_questions_param?
        return render_error(
          I18n.t("ticketing.forms.errors.invalid_schema"),
          status: :unprocessable_entity,
          code: "invalid_schema"
        )
      end

      ActiveRecord::Base.transaction do
        version.save!
        question_attributes.each { |attributes| version.questions.create!(attributes) }
      end

      version = @form.versions.includes(:questions).find(version.id)
      render_success(data: version, serializer_options: serializer_options, status: :created)
    rescue ActiveRecord::RecordInvalid => error
      render_error(errors: error.record.errors, status: :unprocessable_entity)
    end

    def publish
      authorize @version, :publish?

      result = Ticketing::Forms::PublishVersion.call(
        version: @version,
        actor: current_user,
        idempotency_key:
      )
      render_service_result(result, serializer_options: serializer_options)
    end

    private

    def find_form
      @form = Ticketing::RegistrationForm
        .where(event_id: params[:event_id])
        .includes(:event)
        .find(params[:registration_form_id])
      authorize @form, :show?
    end

    def find_version
      @version = @form.versions.includes(:questions).find(params[:id])
    end

    def version_attributes
      params.permit(:version).to_h.symbolize_keys
    end

    def question_attributes
      params.fetch(:questions, []).map do |question|
        question.permit(
          :key, :type, :response_scope, :sensitivity, :label, :help_text, :required, :position,
          options: %i[key label], validation_rules: {}
        ).to_h.symbolize_keys
      end
    end

    def valid_questions_param?
      questions = params[:questions]
      return true unless params.key?(:questions)

      questions.is_a?(Array) && questions.all? { |question| question.respond_to?(:permit) }
    end

    def serializer_options
      { serializer: Ticketing::RegistrationFormVersionSerializer, include: [ :questions ] }
    end
  end
end
