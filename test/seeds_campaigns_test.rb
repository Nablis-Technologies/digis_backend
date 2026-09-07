# frozen_string_literal: true

require "test_helper"

class SeedsCampaignsTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  parallelize(workers: 1)

  setup do
    ActiveRecord::Tasks::DatabaseTasks.truncate_all
  end

  test "preview campaigns and suppression fixtures converge across reruns" do
    load_preview_seed
    load_preview_seed

    organization = Organizations::Organization.find_by!(name: "Addis Music Fest")
    assert_equal 1, Messaging::Campaign.where(organization:, name: "Preview SMS campaign").count
    assert_equal 1, Messaging::CampaignContactList.where(organization:, name: "Preview campaign contacts").count
    assert_equal 1, Messaging::CampaignTemplate.where(organization:, name: "Preview event reminder").count
    assert_equal 1, Messaging::CampaignSuppression.where(organization:, channel: "sms").count
    campaign = Messaging::Campaign.find_by!(organization:, name: "Preview SMS campaign")
    assert_equal 1, campaign.audience_snapshot.recipients.count
  end

  private

  def load_preview_seed
    previous_profile = ENV["DIGIS_SEED_PROFILE"]
    ENV["DIGIS_SEED_PROFILE"] = "preview"
    Prosopite.pause { load Rails.root.join("db/seeds.rb") }
  ensure
    ENV["DIGIS_SEED_PROFILE"] = previous_profile
  end
end
