# frozen_string_literal: true

module Ticketing
  module Forms
    # Loads the published event-wide and ticket-type form versions a registrant
    # must complete. Locks the form set so a publish cannot change the schema
    # halfway through a registration workflow.
    class ApplicableSchema < Core::BaseService
      def initialize(event:, ticket_type:)
        @event = event
        @ticket_type = ticket_type
      end

      def call
        RegistrationForm.transaction do
          forms = applicable_forms.lock.to_a
          versions = published_versions(forms).group_by(&:registration_form_id)

          result = forms.map do |form|
            version = versions.fetch(form.id, []).max_by(&:version)
            return failure(missing_published_version(form)) unless version

            version
          end

          success(result)
        end
      end

      private

      attr_reader :event, :ticket_type

      def applicable_forms
        Ticketing::RegistrationForm
          .active
          .where(event_id: event.id, ticket_type_id: [ nil, ticket_type.id ])
          .order(Arel.sql("ticket_type_id IS NOT NULL"), :created_at, :id)
      end

      def published_versions(forms)
        return [] if forms.empty?

        Ticketing::RegistrationFormVersion
          .published
          .where(registration_form_id: forms.map(&:id))
          .includes(:registration_form, :questions)
          .lock
          .to_a
      end

      def missing_published_version(form)
        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.missing_published_version", name: form.name),
          code: "missing_published_version",
          status: :unprocessable_entity,
          errors: { registration_form_id: [ form.id ] }
        )
      end
    end
  end
end
