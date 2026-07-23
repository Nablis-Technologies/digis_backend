# frozen_string_literal: true

module Events
  class AccessZonesController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::AccessZone
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :access_zones
    self.default_serializer = Events::AccessZoneSerializer

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:access_zone).permit(
        :event_date_id, :type, :name, :code, :active, :sort_order
      )
    end
  end
end
