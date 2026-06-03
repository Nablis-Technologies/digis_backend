require "test_helper"

class AdminOrganizationsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  # exclude :destroy from auto-generation because create_params includes owner_id
  # which is not a column — handled by after_create_hook in the controller
  resource_test model: Organizations::Organization,
                policy_class: Admin::OrganizationPolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/organizations",
                except: [ :destroy ],
                create_params: -> {
                  owner = core_users(:super_admin)
                  { organization: { name: "New Org #{SecureRandom.hex(4)}", owner_id: owner.id } }
                },
                update_params: ->(record) { { organization: { name: "Updated #{record.name}" } } },
                check_attributes: {
                  show: %w[id name slug description social_links followers_count created_at updated_at],
                  index: %w[id name slug description created_at]
                },
                index: {
                  pagination: { per_page: 2 },
                  ordering: { order_by: "name", direction: "asc" }
                },
                policy_results_override: {
                  super_admin: { destroy: true },
                  core_admin: { destroy: false },
                  support: { destroy: false },
                  attendee: { destroy: false }
                }

  # ── Scope tests ──────────────────────────────────
  test "scope returns all orgs for super_admin" do
    scope = Admin::OrganizationPolicy::Scope.new(core_users(:super_admin), Organizations::Organization)
    assert_includes scope.resolve, organizations_organizations(:one)
  end

  test "scope returns all orgs for core_admin" do
    scope = Admin::OrganizationPolicy::Scope.new(core_users(:core_admin), Organizations::Organization)
    assert_includes scope.resolve, organizations_organizations(:one)
  end

  test "scope returns all orgs for support" do
    scope = Admin::OrganizationPolicy::Scope.new(core_users(:support), Organizations::Organization)
    assert_includes scope.resolve, organizations_organizations(:one)
  end

  test "scope returns no orgs for attendee" do
    scope = Admin::OrganizationPolicy::Scope.new(core_users(:attendee), Organizations::Organization)
    assert_not_includes scope.resolve, organizations_organizations(:one)
  end

  # ── transfer_ownership ───────────────────────────
  test "transfer_ownership is permitted for super_admin" do
    org = organizations_organizations(:one)
    target = core_users(:core_admin)

    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: target.id } },
         headers: admin_headers, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal I18n.t("organization.success.transfer_ownership"), body["message"]

    data = body.fetch("data")
    assert_equal target.id, data.dig("owner", "id")

    org.reload
    assert_equal target.id, org.owner.id
  end

  test "transfer_ownership is forbidden for core_admin" do
    org = organizations_organizations(:one)
    target = core_users(:attendee)

    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: target.id } },
         headers: token_headers_for(core_users(:core_admin)), as: :json
    assert_response :forbidden
  end

  test "transfer_ownership fails with missing new_owner_id" do
    org = organizations_organizations(:one)

    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: nil } },
         headers: admin_headers, as: :json
    assert_response :unprocessable_entity
  end

  test "transfer_ownership fails with nonexistent user" do
    org = organizations_organizations(:one)

    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: "00000000-0000-0000-0000-000000000000" } },
         headers: admin_headers, as: :json
    assert_response :unprocessable_entity
  end

  test "transfer_ownership returns i18n error when organization has no current owner" do
    org = Organizations::Organization.create!(name: "Orphaned Org #{SecureRandom.hex(4)}")
    # No memberships created — org has no owner_membership (data corruption case)

    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: core_users(:core_admin).id } },
         headers: admin_headers, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("admin.organizations.errors.no_current_owner"), body["error"]
  end

  test "transfer_ownership promotes existing member to owner" do
    org = organizations_organizations(:one)
    new_owner = core_users(:support)
    existing = org.memberships.create!(user: new_owner, role: :member)

    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: new_owner.id } },
         headers: admin_headers, as: :json
    assert_response :success
    existing.reload
    assert_equal "owner", existing.role
  end

  test "transfer_ownership recovers from RecordNotUnique when membership creation races" do
    org = organizations_organizations(:one)
    new_owner = core_users(:support)
    # Pre-create a member — this is what the race resolves to (another process created it
    # concurrently, so our create! hits the uniqueness constraint)
    existing = org.memberships.create!(user: new_owner, role: :member)

    # Force the create! path: stub the proxy to raise RecordNotUnique.
    # Rails generates a subclass proxy per association; we stub it via the org instance
    # using the association's own target.
    target_proxy = Organizations::Membership.where(organization_id: org.id)
    target_proxy.stubs(:find_by).returns(nil, existing)
    target_proxy.stubs(:create!).raises(ActiveRecord::RecordNotUnique)
    Organizations::Organization.any_instance.stubs(:memberships).returns(target_proxy)

    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: new_owner.id } },
         headers: admin_headers, as: :json
    assert_response :success
    existing.reload
    assert_equal "owner", existing.role
  end

  # ── Owner creation ───────────────────────────────
  test "create without owner_id returns 422" do
    post "/admin/organizations",
         params: { organization: { name: "Orphan Org" } },
         headers: admin_headers, as: :json
    assert_response :unprocessable_entity
  end

  test "create without owner_id returns i18n-translated error" do
    post "/admin/organizations",
         params: { organization: { name: "Orphan Org" } },
         headers: admin_headers, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("admin.organizations.errors.owner_id_required"), body["error"]
  end

  test "transfer_ownership with nonexistent user returns i18n-translated error" do
    org = organizations_organizations(:one)
    post "/admin/organizations/#{org.id}/transfer_ownership",
         params: { organization: { new_owner_id: "00000000-0000-0000-0000-000000000000" } },
         headers: admin_headers, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("admin.organizations.errors.new_owner_id_invalid"), body["error"]
  end

  # ── Destroy (manual since auto-generation fails with owner_id) ──
  test "destroy is permitted for super_admin" do
    org = Organizations::Organization.create!(name: "Temp Org #{SecureRandom.hex(4)}")
    org.memberships.create!(user: core_users(:super_admin), role: :owner)

    delete "/admin/organizations/#{org.id}",
           headers: admin_headers, as: :json
    assert_response :success
    assert_nil Organizations::Organization.find_by(id: org.id)
  end

  test "destroy is forbidden for core_admin" do
    org = organizations_organizations(:two)

    delete "/admin/organizations/#{org.id}",
           headers: token_headers_for(core_users(:core_admin)), as: :json
    assert_response :forbidden
  end
end
