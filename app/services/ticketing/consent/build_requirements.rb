# frozen_string_literal: true

module Ticketing
  module Consent
    # Snapshots every applicable published document and admission coordinate in
    # one locked transaction, then applies only buyer acceptances supplied with
    # the registration submission.
    class BuildRequirements < Core::BaseService
      class Halt < StandardError
        attr_reader :result

        def initialize(result)
          @result = result
          super(result.error.message)
        end
      end

      def initialize(registration:, acceptances: [], actor: nil, **_unused)
        @registration = registration
        @acceptances = acceptances || []
        @actor = actor || registration.user
      end

      def call
        requirements = Registration.transaction do
          locked_registration = Registration.lock.find(registration.id)
          versions = current_versions(locked_registration)
          @requirements_by_scope = load_requirements(locked_registration).group_by do |requirement|
            requirement_scope(requirement)
          end
          requirements = versions.flat_map do |version|
            requirements_for(locked_registration, version)
          end
          apply_acceptances!(requirements)
          reload_requirements(requirements)
        end

        success(requirements)
      rescue Halt => error
        error.result
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.consents.errors.invalid_requirement"),
            code: "invalid_consent_requirement",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      rescue ActiveRecord::RecordNotUnique
        failure(error("consent_requirement_conflict"))
      end

      private

      attr_reader :registration, :acceptances, :actor

      def current_versions(locked_registration)
        documents = Events::ConsentDocument
          .where(event_id: locked_registration.event_id, active: true)
          .lock
          .includes(:consent_document_products)
          .to_a
        return [] if documents.empty?

        Events::ConsentDocumentVersion
          .where(consent_document_id: documents.map(&:id), status: "published")
          .lock
          .includes(consent_document: %i[versions consent_document_products])
          .to_a
          .select do |version|
            current_published_version?(version) &&
              applicable_to_ticket_type?(version, locked_registration.ticket_type_id)
          end
      end

      def load_requirements(locked_registration)
        RegistrationConsentRequirement
          .where(registration_id: locked_registration.id)
          .lock
          .includes(
            :registration,
            :registration_consent,
            consent_document_version: { consent_document: %i[versions consent_document_products] }
          )
          .order(required_at: :desc)
          .to_a
      end

      def applicable_to_ticket_type?(version, ticket_type_id)
        products = version.consent_document.consent_document_products
        products.empty? || products.any? { |product| product.ticket_type_id == ticket_type_id }
      end

      def current_published_version?(version)
        document = version.consent_document
        version.published? && document.active? &&
          document.versions.none? { |candidate| candidate.published? && candidate.id != version.id }
      end

      def requirements_for(locked_registration, version)
        if version.acceptance_scope == "buyer"
          [ find_or_create_requirement(locked_registration, version) ]
        else
          coordinates(locked_registration).map do |package_unit_number, admission_position|
            find_or_create_requirement(
              locked_registration,
              version,
              package_unit_number:,
              admission_position:
            )
          end
        end
      end

      def coordinates(locked_registration)
        1.upto(locked_registration.package_quantity).flat_map do |package_unit_number|
          1.upto(locked_registration.admissions_per_unit_snapshot).map do |admission_position|
            [ package_unit_number, admission_position ]
          end
        end
      end

      def find_or_create_requirement(locked_registration, version, package_unit_number: nil, admission_position: nil)
        key = [ version.id, version.acceptance_scope, package_unit_number, admission_position ]
        existing = @requirements_by_scope.fetch(key, [])
        current = existing.find { |requirement| requirement.pending? || requirement.accepted? }
        return current if current

        historical = existing.find { |requirement| requirement.withdrawn? || requirement.superseded? }
        return historical if historical&.withdrawn?

        requirement = RegistrationConsentRequirement.create!(
          registration: locked_registration,
          consent_document_version: version,
          acceptance_scope: version.acceptance_scope,
          package_unit_number:,
          admission_position:,
          required: version.required,
          subject_user_id: version.acceptance_scope == "buyer" ? locked_registration.user_id : nil,
          status: "pending",
          required_reason: "initial_submission",
          required_by_id: actor&.id,
          required_at: Time.current
        )
        requirement.association(:registration_consent).loaded!
        @requirements_by_scope[key] = [ requirement, *existing ]
        requirement
      end

      def requirement_scope(requirement)
        [
          requirement.consent_document_version_id,
          requirement.acceptance_scope,
          requirement.package_unit_number,
          requirement.admission_position
        ]
      end

      def reload_requirements(requirements)
        ids = requirements.map(&:id)
        return [] if ids.empty?

        loaded = RegistrationConsentRequirement
          .where(id: ids)
          .lock
          .includes(
            :registration,
            :registration_consent,
            consent_document_version: { consent_document: %i[versions consent_document_products] }
          )
          .to_a
          .index_by(&:id)
        ids.map { |id| loaded.fetch(id) }
      end

      def apply_acceptances!(requirements)
        requests = Array(acceptances).map do |raw_acceptance|
          acceptance = normalize_acceptance(raw_acceptance)
          requirement = buyer_requirement_for(requirements, acceptance)
          raise_halt("invalid_submission_consent") unless requirement

          key = acceptance_idempotency_key(acceptance, requirement)
          [ acceptance, requirement, key, idempotency_digest_for(key) ]
        end
        requirement_ids = requests.map { |_acceptance, requirement, _key, _digest| requirement.id }
        raise_halt("invalid_submission_consent") if requirement_ids.uniq.length != requirement_ids.length
        required_ids = requirements.filter_map do |requirement|
          requirement.id if requirement.required? && requirement.acceptance_scope == "buyer"
        end
        raise_halt("missing_required_buyer_consent") unless (required_ids - requirement_ids).empty?

        digests = requests.filter_map { |_acceptance, _requirement, _key, digest| digest }
        raise_halt("acceptance_conflict") if digests.uniq.length != digests.length

        existing_by_digest = load_idempotency_acceptances(digests)
        requests.each do |acceptance, requirement, key, digest|
          result = Accept.call(
            requirement:,
            actor:,
            request_uuid: acceptance[:request_uuid],
            acceptance_method: acceptance[:acceptance_method].presence || "otp",
            content_sha256: acceptance[:content_sha256],
            idempotency_key: key,
            requirement_locked: true,
            idempotency_lookup: digest ? existing_by_digest.fetch(digest, :not_found) : :unchecked
          )
          raise_halt(result.error.code, result) if result.failure?
        end
      end

      def buyer_requirement_for(requirements, acceptance)
        version_id = acceptance[:consent_document_version_id] || acceptance[:version_id]
        return unless version_id
        return if acceptance[:package_unit_number].present? || acceptance[:admission_position].present?

        requirements.find do |requirement|
          requirement.acceptance_scope == "buyer" && requirement.consent_document_version_id.to_s == version_id.to_s
        end
      end

      def normalize_acceptance(value)
        attributes = value.respond_to?(:to_h) ? value.to_h : value
        return {} unless attributes.is_a?(Hash)

        attributes.stringify_keys.symbolize_keys.slice(
          :consent_document_version_id, :version_id, :package_unit_number, :admission_position,
          :request_uuid, :acceptance_method, :content_sha256, :idempotency_key
        )
      end

      def acceptance_idempotency_key(acceptance, requirement)
        acceptance[:idempotency_key]
      end

      def idempotency_digest_for(key)
        return unless key.present?

        normalized = Core::IdempotencyKey.new(key)
        Core::KeyedDigest.digest(namespace: "ticketing-consent-accept", value: normalized.to_s)
      rescue ArgumentError
        nil
      end

      def load_idempotency_acceptances(digests)
        return {} if digests.empty?

        RegistrationConsent.lock.where(idempotency_key_digest: digests).index_by(&:idempotency_key_digest)
      end

      def raise_halt(code, result = nil)
        fail Halt, result || failure(error(code))
      end

      def error(code)
        Core::BusinessError.new(
          I18n.t("ticketing.consents.errors.#{code}"),
          code:,
          status: :unprocessable_entity
        )
      end
    end
  end
end
