Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  scope module: :core do
    post "auth/login", to: "auth#login"
    post "auth/signup", to: "auth#signup"
    post "auth/refresh", to: "auth#refresh"
    post "auth/logout", to: "auth#logout"
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

  scope path: :catalog, module: :catalog do
    resources :product_prices, only: %i[index show create]
    resources :product_quotes, only: %i[create]
    resources :product_inventories, only: %i[index show]
  end

  resources :events, only: [] do
    scope module: :catalog do
      resources :event_products, only: %i[index show create update destroy] do
        post :activate, on: :member
        post :deactivate, on: :member
        patch :update_inventory_configuration, on: :member
      end
    end
  end

  namespace :admin do
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

  scope module: :core do
    get "users/:user_id/following", to: "follows#following"
    get "feed", to: "feed#index"
  end
end
