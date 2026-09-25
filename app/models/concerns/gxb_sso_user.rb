# frozen_string_literal: true

# Included in User by config/initializers/auth_gxb.rb.
module GxbSsoUser
  extend ActiveSupport::Concern

  class IdentityMismatch < StandardError; end

  GXB_DOMAIN = '@gxb.vc'
  NEVER_SIGN_IN = %w[gxbot@gxb.vc].freeze

  module ClassMethods
    # Resolves auth.gxb.vc JWT claims to a local User, or nil to refuse.
    # Matches auth_uid (sub) first, then email. An unknown @gxb.vc email becomes an admin in the single
    # existing account. Other unknown emails are refused. Archived users and gxbot are always refused.
    def find_or_provision_by_auth_claims(claims)
      return unless claims.respond_to?(:[])

      auth_uid = claims['sub'].to_s
      email = claims['email'].to_s.strip.downcase
      return if auth_uid.blank? || email.blank? || NEVER_SIGN_IN.include?(email)

      user = find_by(auth_uid:) || match_by_email!(email, auth_uid)

      if user
        return if user.archived_at? || NEVER_SIGN_IN.include?(user.email.to_s.downcase)

        bind_auth_uid!(user, auth_uid) if user.auth_uid.blank?

        return user
      end

      provision_gxb_user(email, auth_uid, claims['name'])
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("GXB SSO could not save user: #{e.class}")

      nil
    end

    def match_by_email!(email, auth_uid)
      user = find_by('LOWER(email) = ?', email)
      return user if user.nil? || user.auth_uid.blank? || user.auth_uid == auth_uid

      Rails.logger.error("GXB SSO identity mismatch: user #{user.id} is bound to another subject; refusing to rebind")

      raise IdentityMismatch, email
    end

    private

    # Backfill on the first GXB sign-in. The write only lands while the stored value is still blank, so two
    # callbacks for different subjects cannot both bind the same row; the loser sees the other subject and fails.
    def bind_auth_uid!(user, auth_uid)
      where(id: user.id, auth_uid: nil).update_all(auth_uid:, updated_at: Time.current)
      user.reload
      return if user.auth_uid == auth_uid

      Rails.logger.error("GXB SSO identity mismatch: user #{user.id} was bound to another subject; refusing to rebind")

      raise IdentityMismatch, user.email
    end

    def provision_gxb_user(email, auth_uid, name)
      return unless email.end_with?(GXB_DOMAIN)

      account = active.order(:created_at, :id).first&.account
      return if account.nil? || account.archived_at?

      first_name, last_name = name.to_s.strip.split(/\s+/, 2)

      # Devise requires a password. Nobody sees this one; the person signs in with GXB.
      create!(account:, email:, auth_uid:, role: User::ADMIN_ROLE, first_name:, last_name:,
              password: SecureRandom.base58(48))
    end
  end
end
