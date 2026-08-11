require "test_helper"

class OrganizationsOwnerOrganizationsTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers
  include Core::AuditTestHelpers
  include ActiveJob::TestHelper

  test "create requires authentication" do
    post "/organizations/owner", params: { organization: { name: "New Org", organizer_type: "individual", category: "conference" } }, as: :json
    assert_response :unauthorized
  end

  test "create creates an organization with owner membership" do
    user = core_users(:attendee)
    assert_difference("Organizations::Organization.count", 1) do
      post "/organizations/owner",
           params: { organization: { name: "My New Org #{SecureRandom.hex(4)}", organizer_type: "individual", category: "conference" } },
           headers: user_headers, as: :json
    end
    assert_response :created
    data = JSON.parse(response.body).dig("data")
    assert data.key?("id")
    assert data.key?("name")
    assert data.key?("slug")
    org = Organizations::Organization.find(data["id"])
    assert_equal user.id, org.owner.id
  end

  test "create returns created attributes" do
    post "/organizations/owner",
         params: { organization: { name: "Attr Check Org", organizer_type: "individual", category: "conference" } },
         headers: user_headers, as: :json
    assert_response :created
    data = JSON.parse(response.body).dig("data")
    assert data.key?("id")
    assert data.key?("name")
    assert data.key?("slug")
    assert data.key?("description")
    assert data.key?("created_at")
  end

  test "update requires authentication" do
    org = organizations_organizations(:one)
    patch "/organizations/owner/#{org.id}",
          params: { organization: { name: "Updated" } }, as: :json
    assert_response :unauthorized
  end

  test "update is not found for non-member" do
    other_user = core_users(:super_admin)
    org = Organizations::Organization.create!(name: "Others Org #{SecureRandom.hex(4)}", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: other_user, role: :owner)
    patch "/organizations/owner/#{org.id}",
          params: { organization: { name: "Hacked" } },
          headers: user_headers, as: :json
    assert_response :not_found
  end

  test "update succeeds for owner" do
    user = core_users(:attendee)
    org = Organizations::Organization.create!(name: "My Org", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: user, role: :owner)
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
    headers = { "Authorization" => "Bearer #{token}" }
    patch "/organizations/owner/#{org.id}",
          params: { organization: { name: "Updated Org" } },
          headers: headers, as: :json
    assert_response :success
    assert_equal "Updated Org", org.reload.name
  end

  test "destroy requires authentication" do
    org = organizations_organizations(:one)
    delete "/organizations/owner/#{org.id}", as: :json
    assert_response :unauthorized
  end

  test "destroy succeeds for owner" do
    user = core_users(:attendee)
    org = Organizations::Organization.create!(name: "My Org", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: user, role: :owner)
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
    headers = { "Authorization" => "Bearer #{token}" }
    assert_difference("Organizations::Organization.count", -1) do
      delete "/organizations/owner/#{org.id}", headers: headers, as: :json
    end
    assert_response :success
  end

  test "destroy archives an organization that owns an event with an order" do
    user = core_users(:attendee)
    org = Organizations::Organization.create!(name: "Ordered Org", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: user, role: :owner)
    event = Events::Event.create!(
      organization: org,
      created_by: user,
      title: "Ordered Event",
      slug: "ordered-event-#{SecureRandom.hex(4)}",
      status: "draft",
      visibility: "private",
      timezone: "Africa/Addis_Ababa",
      currency: "ETB"
    )
    Orders::Order.create!(
      event:,
      buyer_user: user,
      sales_channel: "online",
      status: "draft",
      charge_currency: "ETB",
      subtotal_minor: 10_000,
      discount_minor: 0,
      subsidy_minor: 0,
      fee_minor: 0,
      tax_minor: 0,
      adjustment_minor: 0,
      total_minor: 10_000,
      settlement_currency: "ETB",
      settlement_total_minor: 10_000,
      exchange_rate: 1,
      exchange_rate_source: "same_currency",
      exchange_rate_expires_at: 10.minutes.from_now,
      expires_at: 10.minutes.from_now,
      idempotency_key_digest: SecureRandom.hex(32),
      creation_request_digest: SecureRandom.hex(32)
    )
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
    headers = { "Authorization" => "Bearer #{token}" }

    assert_no_difference("Organizations::Organization.count") do
      delete "/organizations/owner/#{org.id}", headers: headers, as: :json
    end
    assert_response :success
    assert org.reload.archived?
  end

  test "org with legal acceptance is archived, not deleted" do
    user = core_users(:attendee)
    org = Organizations::Organization.create!(name: "Legal Bound Org", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: user, role: :owner)

    doc = Legal::LegalDocument.create!(
      document_type: "platform_terms", internal_name: "ToS",
      jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
    )
    version = doc.versions.create!(
      version: 1, title: "T", body: "B",
      content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
      status: "published", published_by: core_users(:super_admin), published_at: Time.current,
      created_by: core_users(:super_admin)
    )
    Legal::RecordAcceptance.call(
      subject: org, legal_document_version: version, accepted_by: core_users(:super_admin)
    )

    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
    headers = { "Authorization" => "Bearer #{token}" }
    assert_no_difference("Organizations::Organization.count") do
      delete "/organizations/owner/#{org.id}", headers: headers, as: :json
    end
    assert_response :success
    assert org.reload.archived?
  end

  test "index requires authentication" do
    get "/organizations/owner", as: :json
    assert_response :unauthorized
  end

  test "index returns organizations where current user is a member" do
    user = core_users(:attendee)
    org = Organizations::Organization.create!(name: "My Owner Index Org #{SecureRandom.hex(4)}", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: user, role: :owner)

    get "/organizations/owner", headers: user_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.is_a?(Array)
    assert data.any? { |o| o["id"] == org.id }
  end

  test "show requires authentication" do
    org = organizations_organizations(:one)
    get "/organizations/owner/#{org.id}", as: :json
    assert_response :unauthorized
  end

  test "show returns 404 for orgs where current user is not a member" do
    other_user = core_users(:super_admin)
    org = Organizations::Organization.create!(name: "Others Org #{SecureRandom.hex(4)}", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: other_user, role: :owner)

    get "/organizations/owner/#{org.id}", headers: user_headers, as: :json
    assert_response :not_found
  end

  test "show succeeds for owned organization" do
    user = core_users(:attendee)
    org = Organizations::Organization.create!(name: "My Show Org #{SecureRandom.hex(4)}", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: user, role: :owner)

    get "/organizations/owner/#{org.id}", headers: user_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal org.id, data["id"]
  end

  test "create logs an audit" do
    perform_enqueued_jobs do
      post "/organizations/owner",
           params: { organization: { name: "Audit Org #{SecureRandom.hex(4)}", organizer_type: "individual", category: "conference" } },
           headers: user_headers, as: :json
    end
    assert_response :created
    org = Organizations::Organization.find(JSON.parse(response.body).dig("data", "id"))
    assert_audit_logged(action: "create", auditable: org, actor: core_users(:attendee))
  end
end
