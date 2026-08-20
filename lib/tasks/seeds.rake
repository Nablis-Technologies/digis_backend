# frozen_string_literal: true

namespace :db do
  namespace :seed do
    desc "Load the comprehensive local development seed profile"
    task dev: :environment do
      load Rails.root.join("db/seeds/dev.rb")
    end
  end
end
