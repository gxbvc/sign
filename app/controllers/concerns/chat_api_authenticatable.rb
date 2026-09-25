# frozen_string_literal: true

# GXB Chat (project "sign") calls /chat_api/* with the project API key and the Chat user's GXB identity.
# Copied from ~/projects/sites ChatApiAuthenticatable. The request never signs in through Devise and sets no
# session cookie. A missing or wrong key is 401. Every identity problem is 403.
module ChatApiAuthenticatable
  extend ActiveSupport::Concern

  # GXBot posts to Chat as a system identity, never a person. It must never act as a Sign user.
  DISALLOWED_SYSTEM_EMAILS = GxbSsoUser::NEVER_SIGN_IN

  included do
    before_action :authenticate_chat_api_request!
  end

  private

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def authenticate_chat_api_request!
    key = request.headers['Authorization'].to_s.delete_prefix('Bearer ')
    expected = ENV.fetch('CHAT_API_KEY', '')
    if expected.blank? || key.blank? || !ActiveSupport::SecurityUtils.secure_compare(key, expected)
      return head(:unauthorized)
    end

    auth_uid = request.headers['X-Auth-UID'].presence
    email = request.headers['X-Auth-Email'].to_s.strip.downcase.presence
    return head(:forbidden) if auth_uid.blank? && email.blank?
    return head(:forbidden) if DISALLOWED_SYSTEM_EMAILS.include?(email)

    # A blank header is never a wildcard: find_by(auth_uid: nil) would return an arbitrary unbound user.
    by_uid = auth_uid ? User.active.find_by(auth_uid:) : nil
    by_email = email ? User.active.find_by('LOWER(email) = ?', email) : nil
    return head(:forbidden) if by_uid && by_email && by_uid.id != by_email.id

    @chat_api_user = by_uid || by_email
    return head(:forbidden) unless @chat_api_user&.active_for_authentication?
    return head(:forbidden) if DISALLOWED_SYSTEM_EMAILS.include?(@chat_api_user.email.to_s.downcase)

    return if auth_uid.nil? || @chat_api_user.auth_uid == auth_uid

    # Backfilling a blank auth_uid is allowed. A row already bound to a different subject is refused, never
    # rebound, the same rule GXB sign-in applies (GxbSsoUser).
    if @chat_api_user.auth_uid.present?
      Rails.logger.error("GXB Chat identity mismatch: user #{@chat_api_user.id} is bound to another subject; " \
                         'refusing to rebind')
      return head(:forbidden)
    end

    User.bind_auth_uid!(@chat_api_user, auth_uid)
  rescue GxbSsoUser::IdentityMismatch, ActiveRecord::RecordNotUnique
    head(:forbidden)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end
