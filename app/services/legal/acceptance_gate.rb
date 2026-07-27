# frozen_string_literal: true

module Legal
  module AcceptanceGate
    CONTEXT_TYPES = {
      signup: %w[platform_terms privacy_policy],
      organizer_onboarding: %w[organizer_agreement organizer_fee_schedule],
      checkout: %w[buyer_purchase_terms]
    }.freeze

    class << self
      def required_for(context:)
        types = CONTEXT_TYPES.fetch(context[:context]&.to_sym, [])
        return [] if types.empty?

        docs = Legal::LegalDocument.active
                                .where(document_type: types)
                                .where(jurisdiction_code: jurisdiction_for(context))
                                .where(locale: locale_for(context))
        docs.flat_map do |doc|
          doc.versions.published.map do |version|
            {
              legal_document_id: doc.id,
              document_type: doc.document_type,
              version_id: version.id,
              title: version.title,
              accepted: accepted?(subject: context[:subject], version: version)
            }
          end
        end
      end

      def accepted?(subject:, version:)
        return false if subject.nil?
        Legal::LegalAcceptance.exists?(
          subject_type: subject_type_for(subject),
          subject_id: subject.id,
          legal_document_version_id: version.id
        )
      end

      private

      def subject_type_for(subject)
        case subject
        when Core::User then "user"
        when Organizations::Organization then "organization"
        when Orders::Order then "order"
        end
      end

      def jurisdiction_for(context)
        context[:jurisdiction_code] || "GLOBAL"
      end

      def locale_for(context)
        context[:locale] || "en"
      end
    end
  end
end
