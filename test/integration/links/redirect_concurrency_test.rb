# frozen_string_literal: true

require "test_helper"

module Links
  class RedirectConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @event = events_events(:ready_listing)
      configure_links(enabled: true)
      @link = create_link(slug: "race-#{SecureRandom.hex(5)}", target_type: "event", target_id: @event.id, max_clicks: 1)
    end

    teardown do
      Links::ShortLinkClick.where(short_link_id: @link.id).delete_all
      @link.destroy!
      configure_links(enabled: false)
    end

    test "only one concurrent resolver consumes the final click" do
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do
        Thread.new do
          ready << true
          start.pop
          Links::ShortLink.connection_pool.with_connection do
            Links::Resolve.call(slug: @link.slug, now: Time.current)
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.count(&:success?)
      assert_equal 1, results.count(&:failure?)
      assert_equal 1, @link.reload.click_count
    ensure
      threads&.each(&:join)
    end

    private

    def configure_links(enabled:)
      config = Rails.application.config.x.short_links
      config.enabled = enabled if config
      config.host = "links.test" if config
    end

    def create_link(**attributes)
      Links::ShortLink.create!(
        { slug: "race-#{SecureRandom.hex(5)}", target_type: "event", target_id: @event.id,
          creator_id: core_users(:super_admin).id, canonical: false, click_count: 0 }.merge(attributes)
      )
    end
  end
end
