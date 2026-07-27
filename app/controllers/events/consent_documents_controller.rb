# frozen_string_literal: true

module Events
  class ConsentDocumentsController < Events::ApplicationController
    include Core::Common
    include Core::CommandResponse

    self.model_class = Events::ConsentDocument
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :consent_documents
    self.default_serializer = Events::ConsentDocumentSerializer

    def publish
      @obj = @parent.consent_documents.find_by!(id: params[:id])
      authorize @obj, :publish?

      result = Events::ConsentDocuments::PublishVersion.call(consent_document: @obj, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Events::ConsentDocumentVersionSerializer }
      )
    end

    def activate
      @obj = @parent.consent_documents.find_by!(id: params[:id])
      authorize @obj, :activate?

      result = Events::ConsentDocuments::Activate.call(consent_document: @obj, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Events::ConsentDocumentSerializer, include: [ :versions ] }
      )
    end

    def deactivate
      @obj = @parent.consent_documents.find_by!(id: params[:id])
      authorize @obj, :deactivate?

      result = Events::ConsentDocuments::Deactivate.call(consent_document: @obj, actor: current_user)
      render_service_result(
        result,
        serializer_options: { serializer: Events::ConsentDocumentSerializer, include: [ :versions ] }
      )
    end

    def destroy
      if @obj.versions.published.exists?
        render_business_error(
          Core::BusinessError.new(
            I18n.t("consent_document.errors.delete_published"),
            code: "consent_has_published_version",
            status: :unprocessable_entity
          )
        )
        return
      end

      super
    end

    private

    def consent_document_params
      params.require(:consent_document).permit(:name, :type, :title, :body)
    end

    def model_params
      base = consent_document_params.slice(:name, :type)
      base[:created_by_id] = current_user.id if action_name == "create"
      base
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

    def after_create_hook(document)
      body = consent_document_params[:body]
      return if body.nil?

      title = consent_document_params[:title].presence || document.name
      document.versions.create!(
        version: 1,
        status: "draft",
        title: title,
        body: body,
        content_sha256: ConsentDocumentVersion.content_sha256_for(
          type: document.type, title: title, body: body
        ),
        acceptance_scope: "buyer",
        required: true,
        created_by: current_user
      )
    end

    def after_update_hook(document)
      body = consent_document_params[:body]
      return if body.nil?

      title = consent_document_params[:title].presence || document.name
      digest = ConsentDocumentVersion.content_sha256_for(
        type: document.type, title: title, body: body
      )
      draft = document.versions.draft.first

      if draft
        draft.update!(body: body, content_sha256: digest)
      else
        next_version = (document.versions.maximum(:version) || 0) + 1
        document.versions.create!(
          version: next_version,
          status: "draft",
          title: title,
          body: body,
          content_sha256: digest,
          acceptance_scope: "buyer",
          required: true,
          created_by: current_user
        )
      end
    end
  end
end
