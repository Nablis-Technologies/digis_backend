Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  scope module: :core do
    post "auth/login", to: "auth#login"
    post "auth/signup", to: "auth#signup"
    post "auth/refresh", to: "auth#refresh"
    post "auth/logout", to: "auth#logout"
    get "auth/me", to: "auth#me"
  end

  namespace :events do
    resources :categories, except: %i[new edit]
  end

  namespace :organizations do
    resources :organizations, except: %i[new edit] do
      resources :memberships, except: %i[new edit], controller: "memberships"
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
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
