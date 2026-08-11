# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationPhaseAcceptanceTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update_columns(status: "published", visibility: "public")
      @attendee = core_users(:attendee)
      @manager = core_users(:super_admin)
      @dates = 3.times.map do |index|
        Events::EventDate.create!(
          event: @event,
          name: "Registration day #{index + 1}",
          starts_at: (index + 1).days.from_now,
          ends_at: (index + 1).days.from_now + 4.hours,
          venue_capacity: 100
        )
      end
      @zones = @dates.map do |date|
        Events::AccessZone.create!(
          event: @event,
          event_date: date,
          code: "REGISTRATION-#{date.id}",
          name: "Registration gate",
          type: "venue",
          sort_order: 0
        )
      end
      @product = create_product
      create_forms
      create_retention_policies
      @buyer_document, @buyer_version = create_consent(scope: "buyer")
      create_consent(scope: "admission_slot")
      @access_code = Ticketing::AccessCodes::Create.call(
        ticket_type: @product.ticket_type,
        actor: @manager,
        attributes: { code: "REGISTRATION-PHASE-CODE", max_uses: 5 },
        idempotency_key: "registration-phase-access-code"
      ).value
    end

    test "commits a group-of-three registration across forms, consent, audience, limits, FX, and access" do
      post "/ticket_types/#{@product.ticket_type.id}/registrations",
           params: {
             phone: @attendee.phone,
             package_quantity: 1,
             answers: [
               { question_key: "buyer_name", value: "Ada" },
               *1.upto(3).map do |position|
                 { question_key: "dietary", package_unit_number: 1, admission_position: position, value: "None" }
               end
             ],
             consents: [
               {
                 consent_document_version_id: @buyer_version.id,
                 request_uuid: SecureRandom.uuid,
                 idempotency_key: "registration-phase-buyer-consent",
                 acceptance_method: "otp",
                 content_sha256: @buyer_version.content_sha256
               }
             ],
             access_code: @access_code.plaintext
           },
           headers: user_headers.merge("Idempotency-Key" => "registration-phase-submit"),
           as: :json

      assert_response :created
      registration = Ticketing::Registration.find(response.parsed_body.dig("data", "registration", "id"))
      assert_equal 3, registration.party_size
      submissions = registration.form_submissions.includes(:answers)
      assert_equal 4, submissions.sum { |submission| submission.answers.length }
      assert_equal 4, registration.consent_requirements.count
      assert_equal "accepted", registration.consent_requirements.find_by(acceptance_scope: "buyer").status
      assert_equal "pending_payment", registration.status
      assert_not response.parsed_body.fetch("data").to_s.include?("answer_ciphertext")

      reserve = Ticketing::PurchaseLimits::Reserve.call(
        registration:,
        user: @attendee,
        quantity: 1,
        expires_at: 10.minutes.from_now,
        idempotency_key: "registration-phase-limit"
      )
      assert_predicate reserve, :success?, reserve.error&.message
      assert_equal 1, registration.purchase_limit_allocations.count
      assert_equal 2_500, Catalog::Pricing::Quote.call(product: @product, charge_currency: "USD").value.amount_minor
      assert_equal [ 5_000, 2_500, 2_500 ], @product.product_date_allocations.order(:event_date_id)
        .pluck(:allocation_basis_points)
      assert_equal 3, @product.product_accesses.where(type: "venue").count
      accesses = @product.product_accesses.includes(:product_access_zones)
      assert accesses.all? { |access| access.product_access_zones.any? }
    end

    test "phase boundaries retain workflow handlers and private export scheduling" do
      handlers = Rails.application.config.x.outbox_handlers
      assert handlers.key?("ticketing.registration.waitlist_offer_created")
      assert handlers.key?("ticketing.registration.issuance_ready")
      assert handlers.key?("ticketing.attendee_export.requested")
      assert handlers.key?("ticketing.attendee_export.purge_requested")

      recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")
      assert recurring.key?("process_outbox")
      assert recurring.key?("purge_retention_payloads")
      assert recurring.key?("expire_attendee_exports")

      route_paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
      assert_includes route_paths, "/attendee_exports/:id(.:format)"
      assert_includes route_paths, "/attendee_exports/:id/download_authorizations(.:format)"
    end

    private

    def create_product
      created = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @manager,
        product_attributes: { name: "Registration phase group", type: "ticket" },
        ticket_type_attributes: {
          approval_mode: "automatic",
          audience: "code_or_invitation",
          date_selection: "fixed",
          admissions_per_unit: 3,
          max_packages_per_user: 2
        },
        price_attributes: {
          type: "base", currency: "ETB", amount_minor: 10_000, active_from: 1.hour.ago
        },
        inventory_configuration: { mode: "event_wide", capacity: 100 },
        idempotency_key: "registration-phase-product"
      )
      assert_predicate created, :success?, created.error&.message
      product = created.value
      Catalog::ProductPrice.create!(
        event_product: product, type: "override", currency: "USD", amount_minor: 2_500, active_from: 1.hour.ago
      )
      Catalog::Accesses::Replace.call(
        product:,
        accesses: @dates.flat_map { |date| { event_date_id: date.id, type: "venue", usage_limit: 1 } }
      )
      product.product_accesses.where(type: "venue").find_each do |access|
        access.product_access_zones.create!(access_zone: @zones.fetch(@dates.index { |date| date.id == access.event_date_id }))
      end
      Catalog::DateAllocations::Replace.call(
        product:,
        allocations: @dates.zip([ 5_000, 2_500, 2_500 ]).map do |date, basis_points|
          { event_date_id: date.id, allocation_basis_points: basis_points }
        end
      )
      assert_predicate Catalog::Products::Activate.call(product:, actor: @manager), :success?
      product.reload
    end

    def create_forms
      create_form(name: "Event registration form", ticket_type_id: nil) do |version|
        version.questions.create!(
          key: "buyer_name", type: "short_text", response_scope: "registration", sensitivity: "standard",
          label: "Buyer name", required: true, position: 0, options: [], validation_rules: {}
        )
      end
      create_form(name: "Product dietary form", ticket_type_id: @product.ticket_type.id) do |version|
        version.questions.create!(
          key: "dietary", type: "short_text", response_scope: "admission_slot", sensitivity: "dietary",
          label: "Dietary needs", required: true, position: 0, options: [], validation_rules: {}
        )
      end
    end

    def create_form(name:, ticket_type_id:)
      form = RegistrationForm.create!(event: @event, ticket_type_id:, name:, active: true)
      version = form.versions.create!(version: 1, status: "draft")
      yield version
      version.update!(status: "published", published_by: @manager, published_at: Time.current)
    end

    def create_retention_policies
      now = Time.current
      Core::DataRetentionPolicy.insert_all!(
        %w[registration_free_text consent_evidence].map do |category|
          {
            category:, version: 1, retention_days: 30, action: "erase_payload", status: "active",
            effective_at: 1.minute.ago, created_by_id: @manager.id, created_at: now, updated_at: now
          }
        end
      )
    end

    def create_consent(scope:)
      document = Events::ConsentDocument.create!(
        event: @event,
        name: "Registration #{scope} terms",
        type: scope == "buyer" ? "terms" : "liability_waiver",
        created_by: @manager
      )
      version = document.versions.create!(
        version: 1,
        title: "Registration #{scope} title",
        body: "Registration #{scope} body",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: document.type, title: "Registration #{scope} title", body: "Registration #{scope} body"
        ),
        required: true,
        acceptance_scope: scope,
        status: "draft",
        created_by: @manager
      )
      version.update!(status: "published", published_by: @manager, published_at: Time.current)
      [ document, version ]
    end
  end
end
