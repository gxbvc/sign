# frozen_string_literal: true

# Maps a GXB API person (the Auth `sub` and email from introspection) to a Sign user.
#
# Who is eligible: Sign is a public GXB product, so any active GXB Auth person may use it through GXB API
# (implementation plan 3 and 4.2). Not eligible: GXBot, a person with no usable email, a Sign user that is
# archived or locked (or whose account is archived; never reactivated here), and an email that is already linked
# to another Auth person.
#
# lookup never writes. find_or_create! is the first-use provisioning (plan 4.2). It runs only on an operation
# call with a write token, never on /gxb/access or /openapi.json. It links an existing user by the unique
# users.auth_uid (staff who signed in on the website already have it; an unlinked user with the same email is
# linked once, the same rule as GXB sign-in). A new person gets an ordinary account: a new Sign account of their
# own, with them as its only user. That gives no access to any other account's templates or documents, sends no
# email and creates nobody else (signers named in a payload are never users).
# The unique index on users.auth_uid makes two calls at the same time make one account: the loser's insert fails,
# its transaction (with its new account) rolls back, and it reads the winner's user.
module GxbApiAccounts
  class Refused < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  module_function

  def lookup(claims)
    sub = claims['sub'].to_s
    email = normalize(claims['email'])
    raise Refused.new('not_eligible', 'this GXB account may not use Sign') if never?(email)

    user = User.find_by(auth_uid: sub)
    user ||= unlinked_by_email(email, sub)
    return if user.nil?

    unless user.active_for_authentication? && !never?(user.email)
      raise Refused.new('account_unavailable', 'this Sign account is archived or locked')
    end

    user
  end

  def find_or_create!(claims)
    user = lookup(claims)
    sub = claims['sub'].to_s

    if user
      User.bind_auth_uid!(user, sub) if user.auth_uid.blank?
      return user
    end

    create!(claims, sub)
  rescue GxbSsoUser::IdentityMismatch
    raise Refused.new('identity_mismatch', 'this email is linked to another GXB account in Sign')
  end

  def create!(claims, sub)
    email = normalize(claims['email'])
    if User.domain_of(email).nil?
      raise Refused.new('email_required', 'a plain email address is needed to make a Sign account')
    end

    first_name, last_name = claims['name'].to_s.strip.split(/\s+/, 2)

    ApplicationRecord.transaction(requires_new: true) do
      account = Account.create!(name: claims['name'].to_s.strip.presence || email)

      # Devise needs a password. Nobody sees this one: the person signs in with GXB.
      account.users.create!(email:, auth_uid: sub, role: User::ADMIN_ROLE, first_name:, last_name:,
                            password: SecureRandom.base58(48))
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Another call made this person's user first (or the email belongs to another user).
    winner = User.find_by(auth_uid: sub)
    raise Refused.new('identity_mismatch', 'this email is linked to another GXB account in Sign') if winner.nil?

    winner
  end

  def unlinked_by_email(email, sub)
    return if email.blank?

    user = User.find_by('LOWER(email) = ?', email)
    return if user.nil?
    return user if user.auth_uid.blank? || user.auth_uid == sub

    Rails.logger.error("GXB API identity mismatch: user #{user.id} is bound to another subject")
    raise Refused.new('identity_mismatch', 'this email is linked to another GXB account in Sign')
  end

  def never?(email)
    GxbSsoUser::NEVER_SIGN_IN.include?(normalize(email))
  end

  def normalize(email)
    email.to_s.strip.downcase
  end
end
