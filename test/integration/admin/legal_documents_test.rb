# frozen_string_literal: true

require "test_helper"

module Admin
  class LegalDocumentsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @doc = Legal::LegalDocument.create!(
        document_type: "platform_terms", internal_name: "ToS",
        jurisdiction_code: "GLOBAL", locale: "en", created_by: core_users(:super_admin)
      )
    end

    test "super_admin can create a legal document with a draft version" do
      assert_difference -> { Legal::LegalDocument.count }, 1 do
        post admin_legal_documents_path,
             params: { legal_document: {
               document_type: "privacy_policy", internal_name: "Privacy",
               jurisdiction_code: "GLOBAL", locale: "en",
               title: "Privacy Notice", body: "We respect your data."
             } },
             headers: admin_headers, as: :json
      end
      assert_response :created
      created = Legal::LegalDocument.find_by(document_type: "privacy_policy")
      assert_equal 1, created.versions.draft.count
    end

    test "non-admin cannot create" do
      post admin_legal_documents_path,
           params: { legal_document: {
             document_type: "privacy_policy", internal_name: "Privacy",
             title: "Privacy Notice", body: "x"
           } },
           headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "publish promotes draft to published" do
      @doc.versions.create!(version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "draft", created_by: core_users(:super_admin))
      post publish_admin_legal_document_path(@doc),
           headers: admin_headers, as: :json
      assert_response :ok
      assert @doc.versions.reload.published.exists?
    end

    test "show includes versions with body" do
      @doc.versions.create!(
        version: 1, title: "T", body: "B",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: "T", body: "B"),
        status: "draft", created_by: core_users(:super_admin)
      )

      get admin_legal_document_path(@doc), headers: admin_headers, as: :json

      assert_response :ok
      body = JSON.parse(response.body)
      assert body.dig("data", "versions").present?
      assert_equal "B", body.dig("data", "versions").first["body"]
    end

    test "super_admin can activate a legal document" do
      @doc.update!(active: false)
      post activate_admin_legal_document_path(@doc), headers: admin_headers, as: :json
      assert_response :ok
      assert @doc.reload.active?
      assert_equal I18n.t("legal_document.success.activate"), JSON.parse(response.body)["message"]
    end

    test "super_admin can deactivate a legal document" do
      post deactivate_admin_legal_document_path(@doc), headers: admin_headers, as: :json
      assert_response :ok
      assert_not @doc.reload.active?
      assert_equal I18n.t("legal_document.success.deactivate"), JSON.parse(response.body)["message"]
    end

    test "non-admin cannot activate" do
      post activate_admin_legal_document_path(@doc), headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "PATCH cannot set active (must use activate action)" do
      patch admin_legal_document_path(@doc),
            params: { legal_document: { active: false } },
            headers: admin_headers, as: :json
      assert_response :ok
      assert @doc.reload.active?, "active should be unchanged by PATCH"
    end
  end
end
