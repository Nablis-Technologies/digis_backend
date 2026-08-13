# frozen_string_literal: true

module Events
  module Schedule
    # Advances the event-scoped scanner schedule cursor for a committed
    # schedule/access-policy mutation. The row lock keeps concurrent writers
    # from publishing the same cursor and keeps feed readers from observing a
    # policy change without its new version.
    class BumpVersion < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        # `increment!` performs one atomic SQL counter update, which takes the
        # event row's write lock without re-running unrelated validations or
        # issuing one lock query per materialized date or zone mutation.
        @event.increment!(:schedule_version)
        success(@event)
      end
    end
  end
end
