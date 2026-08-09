# frozen_string_literal: true

module Ticketing
  module ConsentTestHelpers
    def setup_consent_context(package_quantity: 1, admissions_per_unit: 1)
      @event = events_events(:ready_listing)
      @actor = core_users(:attendee)
      @replacement_subject = core_users(:support)
      @ticket_type = create_consent_ticket_type(admissions_per_unit:)
      @registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: @actor,
        created_by: @actor,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity:,
        admissions_per_unit_snapshot: admissions_per_unit,
        party_size: package_quantity * admissions_per_unit,
        status: "pending_payment",
        submitted_at: Time.current
      )
      @retention_policy = Core::DataRetentionPolicy.create!(
        category: "consent_evidence",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.minute.ago,
        created_by: core_users(:super_admin)
      )
    end

    def create_consent_ticket_type(admissions_per_unit: 1)
      Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Consent ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit:
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
    end

    def create_consent_document(scope:, required: true, product_scoped: false, name: nil)
      document = Events::ConsentDocument.create!(
        event: @event,
        name: name || "Consent #{SecureRandom.hex(4)}",
        type: scope == "buyer" ? "terms" : "liability_waiver",
        created_by: core_users(:super_admin)
      )
      version = document.versions.create!(
        version: 1,
        title: "Consent title",
        body: "Consent body",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: document.type, title: "Consent title", body: "Consent body"
        ),
        required:,
        acceptance_scope: scope,
        status: "draft",
        created_by: core_users(:super_admin)
      )
      version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
      Events::ConsentDocumentProduct.create!(consent_document: document, ticket_type: @ticket_type) if product_scoped
      [ document, version ]
    end

    def build_consent_requirements(acceptances: nil, accept_required_buyer: true,
      idempotency_key: "test-build-consents")
      return Core::BaseService::Result.success(pending_consent_requirements) if acceptances.nil? && !accept_required_buyer

      acceptances ||= Events::ConsentDocumentVersion
        .joins(:consent_document)
        .where(events_consent_documents: { event_id: @registration.event_id, active: true }, status: "published",
               acceptance_scope: "buyer", required: true)
        .map do |version|
          {
            consent_document_version_id: version.id,
            request_uuid: SecureRandom.uuid,
            idempotency_key: "#{idempotency_key}-#{version.id}",
            acceptance_method: "otp",
            content_sha256: version.content_sha256
          }
        end
      Ticketing::Consent::BuildRequirements.call(
        registration: @registration,
        acceptances:,
        actor: @actor,
        idempotency_key:
      )
    end

    def pending_consent_requirements
      requirements_by_coordinate = Ticketing::RegistrationConsentRequirement
        .where(registration: @registration, status: %w[pending accepted])
        .index_by do |requirement|
          [
            requirement.consent_document_version_id,
            requirement.acceptance_scope,
            requirement.package_unit_number,
            requirement.admission_position
          ]
        end

      consent_versions.flat_map do |version|
        consent_coordinates(version).map do |package_unit_number, admission_position|
          key = [ version.id, version.acceptance_scope, package_unit_number, admission_position ]
          requirements_by_coordinate[key] ||= Ticketing::RegistrationConsentRequirement.create! do |requirement|
            requirement.registration = @registration
            requirement.consent_document_version = version
            requirement.acceptance_scope = version.acceptance_scope
            requirement.package_unit_number = package_unit_number
            requirement.admission_position = admission_position
            requirement.required = version.required
            requirement.subject_user = @registration.user if version.acceptance_scope == "buyer"
            requirement.status = "pending"
            requirement.required_reason = "initial_submission"
            requirement.required_by = @actor
            requirement.required_at = Time.current
          end
        end
      end
    end

    def requirement_for(version:, scope:, package_unit_number: nil, admission_position: nil)
      Ticketing::RegistrationConsentRequirement.find_by!(
        registration: @registration,
        consent_document_version: version,
        acceptance_scope: scope,
        package_unit_number:,
        admission_position:
      )
    end

    def consent_versions
      Events::ConsentDocumentVersion
        .joins(:consent_document)
        .includes(consent_document: %i[versions consent_document_products])
        .where(
          events_consent_documents: { event_id: @registration.event_id, active: true },
          status: "published"
        )
        .select do |version|
          products = version.consent_document.consent_document_products
          products.empty? || products.any? { |product| product.ticket_type_id == @registration.ticket_type_id }
        end
    end

    def consent_coordinates(version)
      return [ [ nil, nil ] ] if version.acceptance_scope == "buyer"

      1.upto(@registration.package_quantity).flat_map do |package_unit_number|
        1.upto(@registration.admissions_per_unit_snapshot).map do |admission_position|
          [ package_unit_number, admission_position ]
        end
      end
    end

    def accept_consent(requirement:, actor: @actor, request_uuid: SecureRandom.uuid,
      idempotency_key: "test-consent-#{request_uuid}", **attributes)
      Ticketing::Consent::Accept.call(
        requirement:,
        actor:,
        request_uuid:,
        idempotency_key:,
        acceptance_method: "otp",
        **attributes
      )
    end

    def assign_slot!(requirement, subject: @replacement_subject)
      requirement.update!(subject_user: subject)
      requirement
    end
  end
end
