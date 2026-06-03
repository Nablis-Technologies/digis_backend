require "test_helper"

class AdminArtistsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test model: Events::Artist,
                policy_class: Admin::ArtistPolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/artists",
                create_params: -> { { artist: { name: "New Artist #{SecureRandom.hex(4)}", genres: [ "pop" ] } } },
                update_params: ->(record) { { artist: { name: "Updated #{record.name}" } } },
                check_attributes: {
                  show: %w[name slug description genres social_links verified active follower_count profile_url],
                  index: %w[name slug description genres verified active follower_count profile_url]
                },
                index: {
                  pagination: { per_page: 2 },
                  ordering: { order_by: "name", direction: "asc" }
                }
end
