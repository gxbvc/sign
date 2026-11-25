# frozen_string_literal: true

# GET /openapi.json and GET /gxb/access for GXB API (service contract, sections 3 and 5). Both only read: they never
# create a user, an account or any other row.
module GxbApi
  class MetaController < ActionController::API
    include GxbApiAuthenticatable

    MANIFEST = GxbApiManifest.json.freeze
    TTL_S = 300

    # The same document for everybody.
    def manifest
      render json: MANIFEST
    end

    # Eligible: any active GXB Auth person (Sign is a public product), unless GxbApiAccounts refuses them. A person
    # with no Sign account yet gets automatic_on_use: the first write operation makes it.
    def access
      user = GxbApiAccounts.lookup(@gxb_api_claims)

      if user
        render json: access_answer(true, 'none')
      elsif User.domain_of(@gxb_api_claims['email']).present?
        render json: access_answer(true, 'automatic_on_use')
      else
        render json: access_answer(false, 'none')
      end
    rescue GxbApiAccounts::Refused
      render json: access_answer(false, 'none')
    end

    private

    def access_answer(eligible, onboarding)
      { eligible:, onboarding:, operations: eligible ? 'all' : [], ttl_s: TTL_S }
    end
  end
end
