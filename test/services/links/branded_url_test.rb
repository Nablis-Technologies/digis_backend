# frozen_string_literal: true

require "test_helper"

module Links
  class BrandedUrlTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @config = Rails.application.config.x.short_links
      @previous = {
        enabled: @config.enabled,
        host: @config.host,
        protocol: @config.protocol,
        port: @config.port,
        public_app_url: Rails.application.config.x.public_app_url
      }
      configure_links(enabled: true, host: "localhost", protocol: "http", port: "3000")
      Rails.application.config.x.public_app_url = "http://localhost:3000"
    end

    teardown do
      @config.enabled = @previous.fetch(:enabled)
      @config.host = @previous.fetch(:host)
      @config.protocol = @previous.fetch(:protocol)
      @config.port = @previous.fetch(:port)
      Rails.application.config.x.public_app_url = @previous.fetch(:public_app_url)
      Links::ShortLink.where(target_type: "ticket", target_id: @ticket.id).delete_all
      Links::ShortLink.where(target_type: "ticket_transfer").delete_all
      Ticketing::TicketTransfer.where(ticket_id: @ticket.id).delete_all
    end

    test "builds a configured branded origin without duplicate slashes" do
      assert_equal "http://localhost:3000", BrandedUrl.base_url
      assert_equal "http://localhost:3000/summer-festival", BrandedUrl.short_url("/summer-festival")
    end

    test "falls back to a signed direct ticket URL when branded links are disabled" do
      configure_links(enabled: false)

      url = BrandedUrl.ticket(@ticket)
      parsed = URI.parse(url)

      assert_equal "http", parsed.scheme
      assert_equal "localhost", parsed.host
      assert_equal "/public/tickets/#{@ticket.id}", parsed.path
      token = URI.decode_www_form(parsed.query).to_h.fetch("view_token")
      assert Ticketing::GuestTicketViewToken.verify(token).success?
    end

    test "creates and reuses one compact canonical ticket link" do
      first = BrandedUrl.ticket(@ticket)
      second = BrandedUrl.ticket(@ticket)

      assert_match(%r{\Ahttp://localhost:3000/t-[a-z0-9]{6}\z}, first)
      assert_equal first, second
      assert_equal 1, ShortLink.where(canonical: true, target_type: "ticket", target_id: @ticket.id).count
    end

    test "retries a compact slug collision" do
      ShortLink.create!(slug: "t-aaaaaa", custom_url: "https://example.test/collision", click_count: 0)
      slugs = [ "aaaaaa", "bbbbbb" ]

      SecureRandom.expects(:alphanumeric).twice.returns(*slugs)
      url = BrandedUrl.ticket(@ticket)

      assert_equal "http://localhost:3000/t-bbbbbb", url
    end

    test "falls back to a signed URL after compact slug collisions are exhausted" do
      ShortLink.create!(slug: "t-aaaaaa", custom_url: "https://example.test/collision", click_count: 0)

      SecureRandom.expects(:alphanumeric).times(BrandedUrl::MAX_SLUG_ATTEMPTS).returns("aaaaaa")
      url = BrandedUrl.ticket(@ticket)

      assert_match(%r{\Ahttp://localhost:3000/public/tickets/#{@ticket.id}\?view_token=}, url)
    end

    test "falls back to a signed URL when canonical link persistence fails" do
      error = ActiveRecord::RecordInvalid.new(ShortLink.new)
      ShortLink.expects(:create!).raises(error)
      url = BrandedUrl.ticket(@ticket)

      assert_match(%r{\Ahttp://localhost:3000/public/tickets/#{@ticket.id}\?view_token=}, url)
    end

    test "reuses a canonical event link and falls back to the public event route" do
      canonical = ShortLink.create!(
        slug: "summer-festival", target_type: "event", target_id: @event.id, canonical: true, click_count: 0
      )

      assert_equal "http://localhost:3000/summer-festival", BrandedUrl.event(@event)
      canonical.destroy!
      assert_equal "http://localhost:3000/public/events/#{@event.slug}", BrandedUrl.event(@event)
    end

    test "reuses a canonical organization link and falls back to the public route" do
      organization = organizations_organizations(:two)
      canonical = ShortLink.create!(
        slug: "example-promoter", target_type: "organization", target_id: organization.id,
        canonical: true, click_count: 0
      )

      assert_equal "http://localhost:3000/example-promoter", BrandedUrl.organization(organization)
      canonical.destroy!
      assert_equal "http://localhost:3000/organizations/#{organization.id}", BrandedUrl.organization(organization)
    end

    test "creates a compact branded transfer link that resolves with its encrypted token" do
      transfer = create_transfer

      url = BrandedUrl.transfer(transfer, "transfer-secret")

      assert_match(%r{\Ahttp://localhost:3000/x-[a-z0-9]{6}\z}, url)
      link = ShortLink.find_by!(target_type: "ticket_transfer", target_id: transfer.id)
      location = URI.parse(TargetResolver.call("ticket_transfer", transfer.id))
      assert_equal "/public/ticket_transfers/#{transfer.id}", location.path
      token = URI.decode_www_form(location.query).to_h.fetch("token")
      assert_equal Ticketing::TicketTransfer.token_digest_for(token:), transfer.token_digest
      assert_equal link.slug, URI.parse(url).path.delete_prefix("/")
    end

    test "falls back to a direct transfer URL when branded links are disabled" do
      transfer = create_transfer
      configure_links(enabled: false)

      url = BrandedUrl.transfer(transfer, "transfer-secret")

      parsed = URI.parse(url)
      assert_equal "/public/ticket_transfers/#{transfer.id}", parsed.path
      assert_equal "transfer-secret", URI.decode_www_form(parsed.query).to_h.fetch("token")
    end

    private

    def configure_links(enabled:, host: @config.host, protocol: @config.protocol, port: @config.port)
      @config.enabled = enabled
      @config.host = host
      @config.protocol = protocol
      @config.port = port
    end

    def create_transfer
      @ticket.ticket_transfers.create!(
        from_user: @owner,
        to_user: @recipient,
        initiated_by: @owner,
        token: "transfer-secret",
        token_digest: Ticketing::TicketTransfer.token_digest_for(token: "transfer-secret"),
        previous_version: @ticket.credential_version,
        status: "pending",
        expires_at: 1.day.from_now
      )
    end
  end
end
