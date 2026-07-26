# frozen_string_literal: true

namespace :db do
  namespace :seed do
    desc "Load the dev / API-test seed (db/seeds/dev.rb)"
    task dev: :environment do
      load Rails.root.join("db/seeds/dev.rb")
    end
  end
end
