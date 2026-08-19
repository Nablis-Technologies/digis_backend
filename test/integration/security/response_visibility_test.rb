# frozen_string_literal: true

require "test_helper"

module Security
  class ResponseVisibilityTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    PUBLIC_FORBIDDEN_FIELDS = %w[
      business_license_url tin_certificate_url tin_number
      email_ciphertext phone_ciphertext token_ciphertext
      answer answer_ciphertext evidence_digest request_uuid
      qr_token lookup_code account_token provider_payload payout
    ].freeze

    SAFE_SERIALIZER_CONTRACTS = {
      Ticketing::RegistrationAnswerSerializer => [ Ticketing::RegistrationAnswer, %i[answer answer_ciphertext] ],
      Ticketing::InvitationSerializer => [ Ticketing::Invitation, %i[email phone token contact_digest token_digest] ],
      Ticketing::CredentialSerializer => [ Ticketing::Credential, %i[qr_token lookup_code] ],
      Marketplace::SellerPayoutAccountSerializer => [
        Marketplace::SellerPayoutAccount, %i[account_token holder_name_ciphertext]
      ]
    }.freeze

    setup do
      @organization = organizations_organizations(:one)
      @organization.update!(tin_number: "TIN-PRIVATE-#{SecureRandom.hex(4)}")
      attach(@organization.profile, "profile.png", "image/png")
      attach(@organization.banner, "banner.png", "image/png")
      attach(@organization.business_license, "license.pdf", "application/pdf")
      attach(@organization.tin_certificate, "tin.pdf", "application/pdf")
    end

    test "public organization responses expose public media but never private verification data" do
      get "/organizations/#{@organization.id}", as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert data.fetch("profile_url").present?
      assert data.fetch("banner_url").present?
      PUBLIC_FORBIDDEN_FIELDS.each do |field|
        assert_not data.key?(field), "public organization response leaked #{field}"
      end
    end

    test "owner and platform-admin responses require the document endpoint for private media" do
      get "/organizations/owner/#{@organization.id}", headers: admin_headers, as: :json

      assert_response :success
      owner_data = response.parsed_body.fetch("data")
      assert_not owner_data.key?("business_license_url")
      assert_not owner_data.key?("tin_certificate_url")

      get "/admin/organizations/#{@organization.id}", headers: admin_headers, as: :json

      assert_response :success
      admin_data = response.parsed_body.fetch("data")
      assert_not admin_data.key?("business_license_url")
      assert_not admin_data.key?("tin_certificate_url")
    end

    test "sensitive serializer attributes stay outside generic response contracts" do
      SAFE_SERIALIZER_CONTRACTS.each do |serializer_class, (model_class, forbidden_fields)|
        attributes = serializer_class.new(model_class.new).attributes.keys.map(&:to_sym)
        assert_empty attributes & forbidden_fields,
                     "#{serializer_class.name} exposes #{(attributes & forbidden_fields).join(', ')}"
      end
    end

    private

    def attach(attachment, filename, content_type)
      attachment.attach(
        io: StringIO.new(File.binread(Rails.root.join("test/fixtures/files/pixel.png"))),
        filename:,
        content_type:
      )
    end
  end
end
