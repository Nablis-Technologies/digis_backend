require "test_helper"

class AdminVenuesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test model: Events::Venue,
                policy_class: Admin::VenuePolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/venues",
                create_params: -> { { venue: { name: "New Venue #{SecureRandom.hex(4)}" } } },
                update_params: ->(record) { { venue: { name: "Updated #{record.name}" } } },
                check_attributes: {
                  show: %w[name description address city country verified active follower_count],
                  index: %w[name description city country verified active follower_count]
                },
                index: {
                  pagination: { per_page: 2 },
                  ordering: { order_by: "name", direction: "asc" }
                }
end
