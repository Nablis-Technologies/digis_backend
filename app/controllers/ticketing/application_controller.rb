# frozen_string_literal: true

module Ticketing
  class ApplicationController < Core::ApplicationController
    include ActiveStorage::SetCurrent
  end
end
