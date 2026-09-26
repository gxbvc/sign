# frozen_string_literal: true

# Prepended to SessionsController by config/initializers/auth_gxb.rb.
# Staff sign in only with GXB (auth.gxb.vc). GET /sign_in goes there, and a password POST never signs anyone in.
module GxbSsoSignIn
  NOT_CONFIGURED = 'GXB sign-in is not configured on this server.'

  def new
    unless GxbSso.enabled?
      return render('auth_callbacks/refused', locals: { message: NOT_CONFIGURED }, status: :service_unavailable)
    end

    redirect_to GxbSso.authorize_url(session, email: params[:email]), allow_other_host: true
  end

  def create
    redirect_to new_user_session_path
  end
end
