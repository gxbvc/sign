# frozen_string_literal: true

# Prepended to SessionsController by config/initializers/auth_gxb.rb.
# GET /sign_in goes to auth.gxb.vc. GET /sign_in?password=1 keeps the DocuSeal password form.
# A failed password POST recalls #new with POST, so it also keeps the form and its error.
module GxbSsoSignIn
  def new
    return super unless request.get? && params[:password].blank? && GxbSso.enabled?

    redirect_to GxbSso.authorize_url(session, email: params[:email]), allow_other_host: true
  end
end
