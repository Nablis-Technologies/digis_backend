# frozen_string_literal: true

module Admin
  class LegalDocumentsController < Admin::ApplicationController
    include Core::Common
    include Core::CommandResponse

    self.model_class = Legal::LegalDocument
    self.default_serializer = Legal::LegalDocumentSerializer

    def publish
      @obj = Legal::LegalDocument.find(params[:id])
      authorize @obj, :publish?

      result = Legal::PublishVersion.call(legal_document: @obj, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Legal::LegalDocumentVersionSerializer }
      )
    end

    def serializer_profile
      {
        index:  { include: [ :versions ] },
        show:   { include: [ :versions ] },
        create: { include: [ :versions ] },
        update: { include: [ :versions ] }
      }
    end

    def eager_load_config
      { default: [ :versions ] }
    end

    def activate
      @obj = Legal::LegalDocument.find(params[:id])
      authorize @obj, :activate?

      result = Legal::Activate.call(legal_document: @obj, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Legal::LegalDocumentSerializer, include: [ :versions ] }
      )
    end

    def deactivate
      @obj = Legal::LegalDocument.find(params[:id])
      authorize @obj, :deactivate?

      result = Legal::Deactivate.call(legal_document: @obj, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Legal::LegalDocumentSerializer, include: [ :versions ] }
      )
    end

    private

    def legal_document_params
      params.require(:legal_document).permit(
        :document_type, :internal_name, :jurisdiction_code, :locale,
        :title, :body, :commercial_policy_reference
      )
    end

    def model_params
      base = legal_document_params.slice(
        :document_type, :internal_name, :jurisdiction_code, :locale
      )
      base[:created_by_id] = current_user.id if action_name == "create"
      base
    end

    def after_create_hook(document)
      title = legal_document_params[:title].presence || document.internal_name
      body = legal_document_params[:body]
      return if body.nil?

      document.versions.create!(
        version: 1, status: "draft", title: title, body: body,
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: title, body: body),
        commercial_policy_reference: legal_document_params[:commercial_policy_reference],
        created_by: current_user
      )
    end

    def after_update_hook(document)
      body = legal_document_params[:body]
      return if body.nil?

      title = legal_document_params[:title].presence || document.internal_name
      draft = document.versions.draft.first
      if draft
        draft.update!(body: body, title: title,
          content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: title, body: body),
          commercial_policy_reference: legal_document_params[:commercial_policy_reference])
      else
        next_version = (document.versions.maximum(:version) || 0) + 1
        document.versions.create!(
          version: next_version, status: "draft", title: title, body: body,
          content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: title, body: body),
          commercial_policy_reference: legal_document_params[:commercial_policy_reference],
          created_by: current_user
        )
      end
    end
  end
end
