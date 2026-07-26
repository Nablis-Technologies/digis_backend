# frozen_string_literal: true

class RelaxEventsPublishedAtConstraint < ActiveRecord::Migration[8.1]
  def change
    # Cancelling a published event flips status to 'cancelled' while published_at
    # stays set (retained as history). Relax the events_events constraint so that
    # this legitimate state does not violate it. Positional expressions keep
    # db:rollback reversible.
    remove_check_constraint :events_events,
                            "published_at IS NULL OR status::text = 'published'::text",
                            name: "chk_events_events_published_at_requires_published"
    add_check_constraint :events_events,
                         "published_at IS NULL OR status::text = ANY(ARRAY['published','cancelled'])",
                         name: "chk_events_events_published_at_requires_published"
  end
end
