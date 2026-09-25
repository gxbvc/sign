# frozen_string_literal: true

# GXB staff sign-in through auth.gxb.vc (OAuth 2.1 code flow, HS256 JWT signed with the client secret).
# Same pattern as ~/projects/sites. Public signing pages never call authenticate_user!, so they never reach
# this code. Only a failed staff (Devise) authentication for an HTML request is sent to auth.gxb.vc.
# With a blank secret, sign-in falls back to the DocuSeal password form and /auth/callback refuses.
Rails.application.config.auth_gxb = ActiveSupport::OrderedOptions.new
Rails.application.config.auth_gxb.client_id = ENV.fetch('AUTH_GXB_CLIENT_ID', '').presence || 'sign'
Rails.application.config.auth_gxb.client_secret = ENV.fetch('AUTH_GXB_CLIENT_SECRET', '').presence
Rails.application.config.auth_gxb.base_url = ENV.fetch('AUTH_GXB_URL', '').presence || 'https://auth.gxb.vc'

ActiveSupport.on_load(:routes) do
  get 'auth/callback' => 'auth_callbacks#create', as: :auth_callback
end

# Upstream FailureApp (config/initializers/devise.rb) is not reloaded, so this module is defined here.
module GxbSsoFailureRedirect
  REDIRECT_MESSAGES = [nil, :unauthenticated, :timeout].freeze

  # Devise keeps its own answer for API and non-HTML requests (401), recalls (wrong password),
  # locked or archived users (password form with the message), and a blank client secret.
  def redirect
    return super unless GxbSso.enabled? && scope == :user && REDIRECT_MESSAGES.include?(warden_message)

    store_location!
    redirect_to GxbSso.authorize_url(request.session), allow_other_host: true
  end
end

# to_prepare runs after config/initializers/devise.rb has defined FailureApp.
Rails.application.config.to_prepare do
  FailureApp.prepend(GxbSsoFailureRedirect) unless FailureApp < GxbSsoFailureRedirect
  SessionsController.prepend(GxbSsoSignIn)
  User.include(GxbSsoUser)
end
