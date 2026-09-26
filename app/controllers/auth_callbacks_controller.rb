# frozen_string_literal: true

# The return leg of the auth.gxb.vc OAuth handoff started by the Devise failure app or GET /sign_in.
# Same flow as ~/projects/sites. A refusal renders a page with the reason. It never redirects to /sign_in,
# because that goes straight back to GXB and would loop.
class AuthCallbacksController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check

  FAILED = 'GXB sign-in failed. Please try again.'

  def create
    expected_state = session.delete(GxbSso::STATE_KEY).to_s

    return refuse(I18n.t('devise.failure.unauthenticated')) unless GxbSso.enabled?
    return refuse(FAILED) unless GxbSso.valid_state?(expected_state, params[:state].to_s)
    return refuse(FAILED) if params[:code].blank?

    claims = GxbSso.claims_for_code(params[:code].to_s)

    return refuse(FAILED) unless claims

    user = User.find_or_provision_by_auth_claims(claims)

    unless user&.active_for_authentication?
      Rails.logger.warn("GXB SSO refused sign-in for #{claims['email'].to_s.inspect}")

      return refuse("#{claims['email']} does not have access to GXB Sign.")
    end

    return_to = stored_location_for(:user)

    sign_in(user)

    redirect_to safe_return_path(return_to) || root_path
  rescue User::IdentityMismatch
    refuse("#{claims['email']} is linked to a different GXB account. Ask a GXB Sign admin to fix it.")
  end

  private

  def refuse(message)
    render :refused, locals: { message: }, status: :forbidden
  end

  def safe_return_path(path)
    path if path.is_a?(String) && path.start_with?('/') && !path.start_with?('//') && path.exclude?('\\')
  end
end
