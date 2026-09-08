# frozen_string_literal: true

require "test_helper"

module Links
  class ResolveTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      configure_links(enabled: true)
    end

    teardown do
      configure_links(enabled: false)
    end

    test "resolves an internal target while atomically consuming one click" do
      link = create_link(slug: "Summer", target_type: "event", target_id: @event.id, max_clicks: 2)

      result = Resolve.call(slug: "summer", now: Time.current)

      assert_predicate result, :success?, result.error&.message
      assert_equal Rails.application.routes.url_helpers.event_path(@event.id), result.value.location
      assert_equal 1, link.reload.click_count
      assert_equal link.id, result.value.short_link_id
    end

    test "does not resolve or consume clicks while branded links are disabled" do
      link = create_link(slug: "disabled", target_type: "event", target_id: @event.id)
      configure_links(enabled: false)

      result = Resolve.call(slug: link.slug, now: Time.current)

      assert_predicate result, :failure?
      assert_equal "short_links_disabled", result.error.code
      assert_equal 0, link.reload.click_count
    end

    test "rejects an expired link and a link at its click limit" do
      expired = create_link(slug: "expired", target_type: "event", target_id: @event.id, expires_at: 1.minute.ago)
      limited = create_link(slug: "limited", target_type: "event", target_id: @event.id, max_clicks: 1, click_count: 1)

      expired_result = Resolve.call(slug: expired.slug, now: Time.current)
      limited_result = Resolve.call(slug: limited.slug, now: Time.current)

      assert_predicate expired_result, :failure?
      assert_equal "short_link_expired", expired_result.error.code
      assert_predicate limited_result, :failure?
      assert_equal "short_link_click_limit_reached", limited_result.error.code
    end

    test "resolves a validated HTTPS custom URL" do
      link = create_link(slug: "custom", custom_url: "https://example.com/campaign")

      result = Resolve.call(slug: link.slug, now: Time.current)

      assert_predicate result, :success?, result.error&.message
      assert_equal "https://example.com/campaign", result.value.location
    end

    test "resolves a canonical ticket link to a signed public ticket view" do
      link = create_link(slug: "ticket-canonical", target_type: "ticket", target_id: @ticket.id, canonical: true)

      result = Resolve.call(slug: link.slug, now: Time.current)

      assert_predicate result, :success?, result.error&.message
      location = URI.parse(result.value.location)
      assert_equal "/public/tickets/#{@ticket.id}", location.path
      token = URI.decode_www_form(location.query).to_h.fetch("view_token")
      verified = Ticketing::GuestTicketViewToken.verify(token)
      assert_predicate verified, :success?, verified.error&.message
      assert_equal @ticket.id.to_s, verified.value.ticket_id
    end

    test "keeps target types allowlisted and canonical links unique" do
      invalid = Links::ShortLink.new(slug: "invalid", target_type: "User", target_id: @event.id, canonical: true)

      assert_not invalid.valid?
      assert_includes invalid.errors.attribute_names, :target_type

      create_link(slug: "canonical-one", target_type: "event", target_id: @event.id, canonical: true)
      duplicate = Links::ShortLink.new(slug: "canonical-two", target_type: "event", target_id: @event.id, canonical: true)

      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
    end

    test "rejects reserved slugs and non-HTTPS custom URLs" do
      reserved = Links::ShortLink.new(slug: "events", custom_url: "https://example.com")
      insecure = Links::ShortLink.new(slug: "insecure", custom_url: "http://example.com")

      assert_not reserved.valid?
      assert_includes reserved.errors.attribute_names, :slug
      assert_not insecure.valid?
      assert_includes insecure.errors.attribute_names, :custom_url
    end

    test "rejects a link without exactly one internal target or custom URL" do
      neither = Links::ShortLink.new(slug: "neither")
      both = Links::ShortLink.new(
        slug: "both", target_type: "event", target_id: @event.id, custom_url: "https://example.com"
      )

      assert_not neither.valid?
      assert_not both.valid?
    end

    private

    def configure_links(enabled:)
      config = Rails.application.config.x.short_links
      config.enabled = enabled if config
      config.host = "links.test" if config
    end

    def create_link(slug:, target_type: nil, target_id: nil, custom_url: nil,
      canonical: false, expires_at: nil, max_clicks: nil, click_count: 0)
      Links::ShortLink.create!(
        slug:,
        target_type:,
        target_id:,
        custom_url:,
        creator_id: core_users(:super_admin).id,
        canonical:,
        expires_at:,
        max_clicks:,
        click_count:
      )
    end
  end
end
