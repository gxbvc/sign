# frozen_string_literal: true

# The GXB API token check (service contract, section 2) for /openapi.json, /gxb/access and /gxb/v1/*.
# Every request carries the person's exchanged token from the gateway (api.gxb.vc). It is checked by
# introspection at auth.gxb.vc (GxbApiIntrospection) and accepted only when it is active, for exactly Sign's
# audience, from exactly the gxb-api actor, with no origin, from a dynamically registered client, with a read or
# write scope and a subject. A read token may call GET and HEAD only.
# No session cookie, no Devise: the person is GxbApiAccounts' user for the token's subject.
module GxbApiAuthenticatable
  extend ActiveSupport::Concern

  AUDIENCE = 'https://api.sign.gxb.vc'
  ACTOR = { 'sub' => 'gxb-api' }.freeze
  READ_METHODS = %w[GET HEAD].freeze

  included do
    before_action :authenticate_gxb_api!
  end

  private

  def authenticate_gxb_api!
    token = request.authorization.to_s[/\ABearer +(\S+)\z/, 1]
    return gxb_api_error(401, 'unauthenticated', 'a GXB API bearer token is required') if token.blank?

    claims = GxbApiIntrospection.call(token)
    return gxb_api_error(401, 'unauthenticated', 'the token was refused') unless gxb_api_token?(claims)

    if claims['scope'] == 'read' && READ_METHODS.exclude?(request.method)
      return gxb_api_error(403, 'insufficient_scope', 'this route needs a write token')
    end

    @gxb_api_claims = claims
  rescue GxbApiIntrospection::Unavailable => e
    Rails.logger.warn("GXB API introspection unavailable: #{e.message}")
    gxb_api_error(503, 'auth_unavailable', 'GXB Auth could not check the token; try again')
  end

  def gxb_api_token?(claims)
    claims['active'] == true &&
      claims['aud'] == AUDIENCE &&
      claims['act'] == ACTOR &&
      claims['origin'].nil? &&
      %w[read write].include?(claims['scope']) &&
      claims['dynamically_registered'] == true &&
      claims['sub'].is_a?(String) && claims['sub'].present?
  end

  def gxb_api_error(status, code, message)
    render json: { error: { code:, message: } }, status:
  end
end
