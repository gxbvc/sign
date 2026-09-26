# frozen_string_literal: true

# Prepended to PasswordsController by config/initializers/auth_gxb.rb.
# A reset sets a password and signs the person in (sign_in_after_reset_password). Staff use GXB only, so every
# reset page, including the link in an upstream invitation email, goes to GXB sign-in instead.
module GxbSsoNoPasswordReset
  def new
    redirect_to new_user_session_path
  end

  def create
    redirect_to new_user_session_path
  end

  def edit
    redirect_to new_user_session_path
  end

  def update
    redirect_to new_user_session_path
  end
end
