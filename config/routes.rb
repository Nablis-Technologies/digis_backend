Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  scope module: :core do
    post "auth/login", to: "auth#login"
    post "auth/signup", to: "auth#signup"
    post "auth/refresh", to: "auth#refresh"
    post "auth/logout", to: "auth#logout"
    post "auth/reauthenticate", to: "auth#reauthenticate"
    get "auth/me", to: "auth#me"
  end

  scope ":followable_type", constraints: { followable_type: %r{venues|artists|organizations} } do
    scope ":followable_id" do
      post   "follow",    to: "core/follows#create",    as: :follow
      delete "follow",    to: "core/follows#destroy"
      get    "followers", to: "core/followers#index",   as: :followers
    end
  end

  scope module: :events do
    resources :categories, only: %i[index show]
    resources :venues, only: %i[index show]
    resources :artists, only: %i[index show]

    resources :events, only: %i[index show create update] do
      post :publish, on: :member
      resources :event_organizations, only: %i[index show create update destroy] do
        post :revoke, on: :member
        post :activate, on: :member
      end
      resources :event_staff_assignments, only: %i[index show create update destroy] do
        post :suspend, on: :member
        post :revoke, on: :member
        post :activate, on: :member
        post :change_role, on: :member
      end
      resources :event_dates, only: %i[index show create update destroy]
      resources :event_participants, only: %i[index show create update destroy]
      resources :access_zones, only: %i[index show create update destroy]
      resource :recurrence_rule, only: %i[show create update destroy] do
        post :activate, on: :member
        post :deactivate, on: :member
      end
      resources :event_schedule_changes, only: %i[create]
      resources :event_cancellations, only: %i[create]
      resources :event_media, only: %i[index show create update destroy] do
        post :reorder, on: :collection
      end
      resources :event_video_links, only: %i[index show create update destroy]
      resources :consent_documents, only: %i[index show create update destroy] do
        post :publish, on: :member
        post :activate, on: :member
        post :deactivate, on: :member
      end
    end
    resources :public_events, only: %i[index show], param: :slug, path: "public/events"
  end

  get "public/events/:event_slug/products", to: "catalog/public_products#index"
  get "public/events/:event_slug/ticket_types/:ticket_type_id/consent_requirements",
      to: "ticketing/public_consent_requirements#index"

  scope path: :catalog, module: :catalog do
    resources :product_prices, only: %i[index show create]
    resources :product_quotes, only: %i[create]
    resources :product_inventories, only: %i[index show]
    resources :promotions, only: %i[index show create update destroy] do
      post :publish, on: :member
      post :disable, on: :member
      post :quote, on: :member
    end
    resources :promotion_codes, only: %i[index show create] do
      post :reveal, on: :member
    end
  end

  resources :events, only: [] do
    scope module: :catalog do
      resources :event_products, only: %i[index show create update destroy] do
        post :activate, on: :member
        post :deactivate, on: :member
        patch :update_inventory_configuration, on: :member
        resources :product_accesses, only: %i[index] do
          post :replace, on: :collection
          resources :product_access_zones, only: %i[index] do
            post :replace, on: :collection
          end
        end
        resources :product_date_allocations, only: %i[index] do
          post :replace, on: :collection
        end
      end
    end
  end

  resources :events, only: [] do
    post :order_quotes, to: "orders/order_quotes#create"
    resources :orders, only: :create, controller: "orders/orders"
  end

  resources :orders, only: [] do
    resources :payment_attempts, only: :create, controller: "orders/payment_attempts"
    post :restart, on: :member, controller: "orders/orders"
  end

  post "payments/:provider/webhook", to: "orders/payment_webhooks#create"

  resources :events, only: [] do
    resources :registration_forms, controller: "ticketing/registration_forms", only: %i[index show create update destroy] do
      resources :versions, controller: "ticketing/registration_form_versions", only: %i[index show create] do
        post :publish, on: :member
      end
    end
  end

  resources :events, only: [] do
    resources :attendee_exports, controller: "ticketing/attendee_exports", only: %i[create]
  end

  resources :attendee_exports, controller: "ticketing/attendee_exports", only: %i[show] do
    post :download_authorizations, on: :member
  end

  resources :registration_answers, only: %i[show], controller: "ticketing/registration_answers" do
    post :revise, on: :member
  end

  resources :registrations, only: [] do
    resources :consents, only: :index, controller: "ticketing/registration_consents" do
      post :accept, on: :member
    end
    resource :purchase_limit_override, only: :create, controller: "ticketing/purchase_limit_overrides"
  end

  resources :registration_consents, only: [] do
    resource :withdrawal, only: :create, controller: "ticketing/registration_consent_withdrawals"
  end

  resources :ticket_types, only: [] do
    resources :registrations, only: :create, controller: "ticketing/registrations"
  end

  # Workflow endpoints delegate all state transitions to idempotent commands.
  resources :registrations, only: :show, controller: "ticketing/registrations"

  resources :registrations, only: [] do
    member do
      post :approve, controller: "ticketing/registration_decisions"
      post :reject, controller: "ticketing/registration_decisions"
      post :reconsider, controller: "ticketing/registration_decisions"
      post :enqueue_waitlist, controller: "ticketing/waitlist_offers", action: :enqueue
      post :accept_waitlist_offer, controller: "ticketing/waitlist_offers", action: :accept
    end
  end

  resources :ticket_types, only: [] do
    post :offer_next, on: :member, controller: "ticketing/waitlist_offers"
  end

  post "events/:event_id/complimentary_tickets", to: "ticketing/complimentary_tickets#create"

  resources :events, only: [] do
    resources :event_products, only: [] do
      resource :ticket_type, only: %i[show create update destroy], controller: "ticketing/ticket_types" do
        resources :access_codes, only: %i[index show create destroy], controller: "ticketing/access_codes"
        resources :invitations, only: %i[index show create destroy], controller: "ticketing/invitations"
      end
    end
  end

  post "ticketing/audience_authorizations", to: "ticketing/audience_authorizations#create"
  post "scanner/auth", to: "ticketing/scanner/auth#create"

  resources :tickets, only: [] do
    resource :suspension, only: :create, controller: "ticketing/suspensions" do
      post :restore
      post :resolve
    end
    resource :delegation, only: :create, controller: "ticketing/delegations" do
      post :cancel
      patch :reassign
    end
    resources :credential_claims, only: :create, controller: "ticketing/credential_claims"
    resources :transfers, only: :create, controller: "ticketing/transfers"
  end

  resources :credential_claims, only: [] do
    post :accept, on: :member, controller: "ticketing/credential_claims"
  end

  resources :ticket_transfers, only: [] do
    post :accept, on: :member, controller: "ticketing/transfers"
    post :decline, on: :member, controller: "ticketing/transfers"
    post :cancel, on: :member, controller: "ticketing/transfers"
  end

  namespace :admin do
    namespace :commercial do
      resources :fee_schedules, only: %i[index show create update] do
        resources :fee_schedule_versions, only: %i[index create], controller: "fee_schedule_versions"
      end
      resources :fee_schedule_versions, only: %i[show update], controller: "fee_schedule_versions" do
        member do
          post :simulate
          post :submit
          post :approve
          post :reject
          post :schedule
          post :activate
          post :terminate
          post :deliver_notice
        end
      end
      resources :programs, only: %i[index show create update]
      resources :assignments, only: %i[index show create] do
        member do
          post :submit
          post :approve
          post :reject
          post :activate
          post :terminate
        end
      end
      resources :simulations, only: %i[index show create]
      resources :subsidy_budgets, only: %i[index show create update]
    end

    resources :users, except: %i[new edit] do
      member do
        post :deactivate
        post :reactivate
      end
      resources :roles, only: %i[index create destroy], controller: "user_roles", param: :role_id
    end
    resources :roles, except: %i[new edit]
    resources :permissions, except: %i[new edit]
    resources :categories, except: %i[new edit]
    resources :venues, except: %i[new edit]
    resources :artists, except: %i[new edit]
    resources :events, except: %i[new edit] do
      member do
        post :publish
        post :unpublish
      end
    end
    resources :organizations, except: %i[new edit] do
      member do
        post :transfer_ownership
      end
      resources :memberships, only: %i[index show create update destroy]
    end

    resources :legal_documents, except: %i[new edit] do
      member do
        post :publish
        post :activate
        post :deactivate
      end
    end
    resources :data_retention_policies, except: %i[new edit destroy]
    resources :data_retention_holds, only: %i[index show create] do
      member do
        post :release
      end
    end

    post "organizations/:id/verification/approve",              to: "verifications#approve"
    post "organizations/:id/verification/reject",               to: "verifications#reject"
    post "organizations/:id/verification/request_modification", to: "verifications#request_modification"
  end

  scope module: :organizations do
    resources :owner_organizations, only: %i[index show create update destroy],
              path: "organizations/owner" do
      resources :memberships, only: %i[index show create update destroy],
                controller: "owner_memberships" do
        member do
          patch :suspend
          patch :activate
        end
      end
      member do
        patch :documents
        get "documents/:document_type", to: "owner_organizations#download", as: :download_document
      end
    end

    post "organizations/owner/:organization_id/verification/submit",   to: "verifications#submit"
    post "organizations/owner/:organization_id/verification/resubmit", to: "verifications#resubmit"

    resources :organizations, only: %i[index show], path: "organizations"
  end

  scope path: :commercial, module: :commercial do
    get "organizations/:organization_id/terms", to: "organization_terms#show",
      as: :commercial_organization_terms
    resources :events, only: [] do
      resources :event_payer_selections, only: %i[index show create]
    end
  end

  scope module: :core do
    get "users/:user_id/following", to: "follows#following"
    get "feed", to: "feed#index"
  end
end
