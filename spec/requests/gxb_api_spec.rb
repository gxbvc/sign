# frozen_string_literal: true

# GXB API (api.gxb.vc) service contract: the token check, /openapi.json, /gxb/access, first-use provisioning
# and the /gxb/v1 operations. Contract: the GXB API service contract, section 9 checklist.
RSpec::Matchers.define_negated_matcher :not_change, :change unless RSpec::Matchers.method_defined?(:not_change)

describe 'GXB API' do
  let(:secret) { 'test-introspection-secret' }
  let(:introspect_url) { 'https://auth.gxb.vc/oauth/introspect' }
  let(:account) { create(:account) }
  let!(:user) { create(:user, account:, email: 'staff@gxb.vc', auth_uid: 'sub-staff') }
  let(:other_account) { create(:account) }
  let(:other_user) { create(:user, account: other_account, email: 'other@example.com', auth_uid: 'sub-other') }

  around do |example|
    previous = ENV.fetch('AUTH_INTROSPECTION_SECRET', nil)
    ENV['AUTH_INTROSPECTION_SECRET'] = secret
    GxbApiIntrospection.clear_cache!
    example.run
  ensure
    ENV['AUTH_INTROSPECTION_SECRET'] = previous
    GxbApiIntrospection.clear_cache!
  end

  # Auth's real introspection shape for an exchanged token (contract 2.1).
  def claims(overrides = {})
    now = Time.now.to_i
    { 'active' => true, 'sub' => 'sub-staff', 'email' => 'staff@gxb.vc', 'name' => 'Staff Person',
      'client_id' => 'dyn_0123456789abcdef0123456789abcdef', 'aud' => 'https://api.sign.gxb.vc',
      'token_type' => 'Bearer', 'exp' => now + 180, 'iat' => now, 'staff' => false,
      'dynamically_registered' => true, 'scope' => 'write', 'origin' => nil,
      'act' => { 'sub' => 'gxb-api' } }.merge(overrides.stringify_keys)
  end

  def token_for(overrides = {})
    token = "tok-#{SecureRandom.hex(8)}"
    stub_request(:post, introspect_url)
      .with(body: { 'token' => token }, headers: { 'Authorization' => "Bearer #{secret}" })
      .to_return(status: 200, body: claims(overrides).to_json, headers: { 'Content-Type' => 'application/json' })
    token
  end

  def bearer(token, extra = {})
    { 'Authorization' => "Bearer #{token}" }.merge(extra)
  end

  def read_token(overrides = {})
    token_for(overrides.merge('scope' => 'read'))
  end

  def get_json(path, token, params = {})
    get path, params:, headers: bearer(token)
    response.parsed_body
  end

  def post_json(path, token, body, headers = {})
    post path, params: body.to_json, headers: bearer(token, 'Content-Type' => 'application/json').merge(headers)
    response.parsed_body
  end

  def table_counts
    [User, Account, Template, Submission, Submitter, TemplateFolder, GxbApiIdempotencyKey].map(&:count)
  end

  def expect_error(status, code = nil)
    expect(response).to have_http_status(status)
    expect(response.parsed_body['error']).to include('code', 'message')
    expect(response.parsed_body.dig('error', 'code')).to eq(code) if code
  end

  describe 'token check' do
    let!(:template) { create(:template, account:, author: user, name: 'Advisory Agreement') }

    it "accepts Auth's real answer and runs as the user mapped from sub" do
      create(:template, account: other_account, author: other_user, name: 'Advisory Secret')

      body = get_json('/gxb/v1/templates', read_token)

      expect(response).to have_http_status(:ok)
      expect(body['data'].pluck('id')).to eq([template.id])
      expect(response.headers['Set-Cookie']).to be_blank
    end

    it 'refuses with 401: no bearer, inactive, another aud, act null, act chat-mcp, origin set, and more' do
      get '/gxb/v1/templates'
      expect_error(401, 'unauthenticated')

      [{ 'active' => false }, { 'aud' => 'https://api.notes.gxb.vc' }, { 'aud' => ['https://api.sign.gxb.vc'] },
       { 'act' => nil }, { 'act' => { 'sub' => 'chat-mcp' } }, { 'origin' => 'https://evil.example' },
       { 'dynamically_registered' => false }, { 'scope' => nil }, { 'scope' => 'admin' }, { 'sub' => '' }]
        .each do |bad|
        get '/gxb/v1/templates', headers: bearer(token_for(bad))
        expect(response).to have_http_status(:unauthorized), bad.inspect
      end

      stub_request(:post, introspect_url).with(body: { 'token' => 'refused' }).to_return(status: 401, body: '{}')
      get '/gxb/v1/templates', headers: bearer('refused')
      expect_error(401)
    end

    it 'answers 503, not 401, when Auth is unreachable, fails, limits us, or the secret is missing' do
      [->(s) { s.to_return(status: 500) }, ->(s) { s.to_return(status: 429) }, lambda(&:to_timeout),
       ->(s) { s.to_raise(SocketError) }, ->(s) { s.to_return(status: 200, body: 'not json') }].each do |answer|
        answer.call(stub_request(:post, introspect_url).with(body: { 'token' => 'down' }))
        get '/gxb/v1/templates', headers: bearer('down')
        expect_error(503, 'auth_unavailable')
        WebMock.reset!
      end

      ENV['AUTH_INTROSPECTION_SECRET'] = ''
      get '/openapi.json', headers: bearer('any')
      expect_error(503)
    end

    it 'refuses a read token on every POST route with 403, and a write token may call a GET route' do
      expect do
        post_json('/gxb/v1/templates', read_token, { name: 'X' })
        expect_error(403, 'insufficient_scope')
        post_json('/gxb/v1/signature_requests', read_token,
                  { template_id: template.id, submitters: [{ email: 'a@example.com' }], confirmation: 'x' })
        expect_error(403, 'insufficient_scope')
      end.not_to(change { table_counts })

      get_json('/gxb/v1/templates', token_for)
      expect(response).to have_http_status(:ok)
    end

    it 'keeps an active answer for at most 60 s and never past exp, keyed by a SHA-256 of the token' do
      token = read_token
      2.times { get '/gxb/v1/templates', headers: bearer(token) }
      expect(a_request(:post, introspect_url)).to have_been_made.once
      expect(GxbApiIntrospection::CACHE.exist?(Digest::SHA256.hexdigest(token))).to be(true)
      expect(GxbApiIntrospection::CACHE.exist?(token)).to be(false)

      travel 61.seconds do
        get '/gxb/v1/templates', headers: bearer(token)
        expect(a_request(:post, introspect_url)).to have_been_made.twice
      end

      short = read_token('exp' => Time.now.to_i + 5)
      get '/gxb/v1/templates', headers: bearer(short)
      travel 6.seconds do
        get '/gxb/v1/templates', headers: bearer(short)
      end
      expect(a_request(:post, introspect_url).with(body: { 'token' => short })).to have_been_made.twice
    end

    it 'never keeps an inactive answer' do
      token = token_for('active' => false)
      2.times { get '/gxb/v1/templates', headers: bearer(token) }

      expect(a_request(:post, introspect_url)).to have_been_made.twice
    end

    it "gives 404 for another account's record, never the record" do
      secret_template = create(:template, account: other_account, author: other_user, name: 'Advisory Secret')

      get_json("/gxb/v1/templates/#{secret_template.id}", read_token)
      expect_error(404, 'not_found')

      get_json('/gxb/v1/signature_requests/preview', read_token,
               template_id: secret_template.id, submitters: [{ email: 'x@example.com' }].to_json)
      expect_error(404)

      body = get_json('/gxb/v1/templates', read_token, q: 'Secret')
      expect(body['data']).to eq([])
      expect(response.body).not_to include('Advisory Secret')
    end
  end

  describe 'GET /gxb/access' do
    it 'gives a known allowed person eligible true with all operations' do
      body = get_json('/gxb/access', read_token)

      expect(response).to have_http_status(:ok)
      expect(body).to eq('eligible' => true, 'onboarding' => 'none', 'operations' => 'all', 'ttl_s' => 300)
    end

    it 'gives an Auth person Sign does not know eligible true with automatic_on_use, and makes nothing' do
      expect do
        body = get_json('/gxb/access', read_token('sub' => 'sub-new', 'email' => 'new.person@example.com'))
        expect(response).to have_http_status(:ok)
        expect(body).to eq('eligible' => true, 'onboarding' => 'automatic_on_use', 'operations' => 'all',
                           'ttl_s' => 300)
      end.not_to(change { table_counts })
    end

    it 'gives eligible false to people who may not use Sign, with 200, and makes nothing' do
      create(:user, account:, email: 'bound@example.com', auth_uid: 'sub-bound')
      archived = create(:user, account:, email: 'gone@example.com', auth_uid: 'sub-gone', archived_at: Time.current)

      cases = [{ 'sub' => 'sub-bot', 'email' => 'GXBot@gxb.vc' },
               { 'sub' => 'sub-noemail', 'email' => nil },
               { 'sub' => 'sub-bad', 'email' => 'a@b@example.com' },
               { 'sub' => 'sub-thief', 'email' => 'bound@example.com' },
               { 'sub' => archived.auth_uid, 'email' => archived.email }]

      expect do
        cases.each do |person|
          body = get_json('/gxb/access', read_token(person))
          expect(response).to have_http_status(:ok)
          expect(body).to eq('eligible' => false, 'onboarding' => 'none', 'operations' => [], 'ttl_s' => 300),
                          person.inspect
        end
      end.not_to(change { table_counts })
    end
  end

  describe 'GET /openapi.json' do
    it 'answers 200 and the same document for two different people, and makes nothing' do
      expect do
        first = get_json('/openapi.json', read_token)
        expect(response).to have_http_status(:ok)
        second = get_json('/openapi.json', read_token('sub' => 'sub-new', 'email' => 'new.person@example.com'))

        expect(second).to eq(first)
        expect(first['openapi']).to eq('3.1.0')
      end.not_to(change { table_counts })
    end

    it 'lists the six sign operations, each with x-gxb and effects from what the route does' do
      doc = GxbApiManifest.document
      operations = doc['paths'].flat_map { |path, verbs| verbs.map { |verb, op| [op['operationId'], verb, path, op] } }
      effects = operations.to_h { |id, _, _, op| [id, op.dig('x-gxb', 'effects')] }

      expect(effects).to eq('sign.template.list' => [], 'sign.template.create' => ['state_change'],
                            'sign.template.get' => [], 'sign.document.list' => [],
                            'sign.signature_request.preview' => [],
                            'sign.signature_request.create' => %w[state_change external_send])
      expect(operations.select { |_, verb, _, _| verb == 'get' }.map(&:first))
        .to match_array(effects.select { |_, e| e.empty? }.keys)
      send_op = operations.find { |id, _, _, _| id == 'sign.signature_request.create' }.last
      expect(send_op.dig('x-gxb', 'approval')).to eq('required')

      operations.each do |id, verb, path, _|
        expect(Rails.application.routes.recognize_path(path.sub('{template_id}', '1'), method: verb)[:controller])
          .to eq('gxb_api/operations'), id
      end
    end

    it 'changes info.version whenever the document changes' do
      doc = GxbApiManifest.document
      body = doc.merge('info' => doc['info'].except('version'))

      expect(doc['info']['version']).to eq(GxbApiManifest.revision(body))
      expect(doc['info']['version']).to eq("sign-#{Digest::SHA256.hexdigest(JSON.generate(body))[0, 16]}")

      changed = body.deep_dup
      changed['paths']['/gxb/v1/templates']['get']['x-gxb']['effects'] = ['state_change']
      expect(GxbApiManifest.revision(changed)).not_to eq(doc['info']['version'])
    end
  end

  describe 'first-use provisioning' do
    let(:new_person) { { 'sub' => 'sub-new', 'email' => 'New.Person@Example.com', 'name' => 'New Person' } }

    it 'gives a new Auth user one ordinary account on their first operation, and reuses it after' do
      expect do
        body = post_json('/gxb/v1/templates', token_for(new_person), { name: 'My NDA' })
        expect(response).to have_http_status(:created)
        expect(body.dig('data', 'name')).to eq('My NDA')
      end.to change(User, :count).by(1).and change(Account, :count).by(1)

      created = User.find_by!(auth_uid: 'sub-new')
      expect(created.email).to eq('new.person@example.com')
      expect(created.account).not_to eq(account)
      expect(created.account.users).to eq([created])
      expect(Template.find(response.parsed_body.dig('data', 'id')).account).to eq(created.account)

      expect do
        post_json('/gxb/v1/templates', token_for(new_person), { name: 'Second' })
        body = get_json('/gxb/v1/templates', read_token(new_person))
        expect(body['data'].pluck('name')).to contain_exactly('My NDA', 'Second')
      end.not_to change(User, :count)
    end

    it 'never sees or sends anything for the new person: no access to other accounts, no email' do
      create(:template, account:, author: user, name: 'Staff Template')
      ActionMailer::Base.deliveries.clear

      post_json('/gxb/v1/templates', token_for(new_person), { name: 'Mine' })
      body = get_json('/gxb/v1/templates', read_token(new_person))

      expect(body['data'].pluck('name')).to eq(['Mine'])
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(Sidekiq::Worker.jobs.pluck('class')).not_to include('SendSubmitterInvitationEmailJob')
    end

    it 'makes no account on a read, on /gxb/access or on /openapi.json (a search alone)' do
      expect do
        get_json('/gxb/access', read_token(new_person))
        get_json('/openapi.json', read_token(new_person))
        empty = { 'data' => [], 'meta' => { 'next_cursor' => nil, 'has_more' => false } }
        expect(get_json('/gxb/v1/templates', read_token(new_person))).to eq(empty)
        expect(get_json('/gxb/v1/documents', token_for(new_person))['data']).to eq([])
        get_json('/gxb/v1/templates/1', read_token(new_person))
        expect(response).to have_http_status(:not_found)
      end.not_to(change { table_counts })
    end

    it 'makes no account when the token fails, when Auth is down, or for a read token on a write route' do
      stub_request(:post, introspect_url).with(body: { 'token' => 'down' }).to_return(status: 503)

      expect do
        post_json('/gxb/v1/templates', token_for(new_person.merge('active' => false)), { name: 'X' })
        post_json('/gxb/v1/templates', token_for(new_person.merge('act' => nil)), { name: 'X' })
        post_json('/gxb/v1/templates', 'down', { name: 'X' })
        post_json('/gxb/v1/templates', read_token(new_person), { name: 'X' })
      end.not_to(change { table_counts })
    end

    it 'links an existing unlinked user by email on a write, never on a read, and never rebinds' do
      staff = create(:user, account:, email: 'ricky@gxb.vc', auth_uid: nil)
      person = { 'sub' => 'sub-ricky', 'email' => 'ricky@gxb.vc' }

      get_json('/gxb/v1/templates', read_token(person))
      expect(response).to have_http_status(:ok)
      expect(staff.reload.auth_uid).to be_nil

      expect do
        post_json('/gxb/v1/templates', token_for(person), { name: 'Linked' })
      end.not_to change(User, :count)
      expect(staff.reload.auth_uid).to eq('sub-ricky')

      post_json('/gxb/v1/templates', token_for('sub' => 'sub-impostor', 'email' => 'ricky@gxb.vc'), { name: 'X' })
      expect_error(403, 'identity_mismatch')
      expect(staff.reload.auth_uid).to eq('sub-ricky')
    end

    it 'never reactivates an archived user and refuses GXBot' do
      user.update!(archived_at: Time.current)

      expect do
        post_json('/gxb/v1/templates', token_for, { name: 'X' })
        expect_error(403, 'account_unavailable')
        post_json('/gxb/v1/templates', token_for('sub' => 'sub-bot', 'email' => 'gxbot@gxb.vc'), { name: 'X' })
        expect_error(403, 'not_eligible')
      end.not_to(change { table_counts })
      expect(user.reload.archived_at).to be_present
    end

    it 'reads the winner when another call made the same person first (unique auth_uid)' do
      # The other call committed its user after our lookup found nothing.
      winner = create(:user, account: create(:account), email: 'winner@example.com', auth_uid: 'sub-new')
      allow(GxbApiAccounts).to receive(:lookup).and_return(nil)

      expect do
        post_json('/gxb/v1/templates', token_for(new_person), { name: 'Race' })
      end.to not_change(User, :count).and not_change(Account, :count) # our new account rolled back

      expect(response).to have_http_status(:created)
      expect(Template.find(response.parsed_body.dig('data', 'id')).author).to eq(winner)
    end
  end

  describe 'operations' do
    let!(:old_template) do
      create(:template, account:, author: user, name: 'Beta Lease', created_at: 3.days.ago)
    end
    let!(:mid_template) { create(:template, account:, author: user, name: 'Alpha NDA', created_at: 2.days.ago) }
    let!(:new_template) { create(:template, account:, author: user, name: 'Gamma Offer', created_at: 1.day.ago) }

    it 'reads filter, sort and fields as JSON text in the query' do
      body = get_json('/gxb/v1/templates', read_token,
                      filter: { and: [{ field: 'created_at', op: 'gte', value: 2.5.days.ago.iso8601 },
                                      { field: 'author_email', op: 'eq', value: 'me' }] }.to_json,
                      sort: ['name'].to_json, fields: ['name'].to_json)

      expect(response).to have_http_status(:ok)
      expect(body['data']).to eq([{ 'id' => mid_template.id, 'name' => 'Alpha NDA' },
                                  { 'id' => new_template.id, 'name' => 'Gamma Offer' }])

      get_json('/gxb/v1/templates', read_token, filter: { and: [{ field: 'secret', op: 'eq', value: 1 }] }.to_json)
      expect_error(422, 'invalid_arguments')
      get_json('/gxb/v1/templates', read_token, sort: 'name')
      expect_error(422)
      get_json('/gxb/v1/templates', read_token, filter: '{"and": [')
      expect_error(422)
    end

    it 'gives a working next_cursor when a list is cut, and the next page continues it' do
      first = get_json('/gxb/v1/templates', read_token, limit: 2)

      expect(first['data'].pluck('id')).to eq([new_template.id, mid_template.id])
      expect(first['meta']['has_more']).to be(true)

      second = get_json('/gxb/v1/templates', read_token, limit: 2, cursor: first['meta']['next_cursor'])
      expect(second['data'].pluck('id')).to eq([old_template.id])
      expect(second['meta']).to eq('next_cursor' => nil, 'has_more' => false)

      get_json('/gxb/v1/templates', read_token, cursor: 'garbage')
      expect_error(422)
      get_json('/gxb/v1/templates', read_token, limit: 101)
      expect_error(422)
    end

    it 'loads one template with roles, fields and a version' do
      body = get_json("/gxb/v1/templates/#{mid_template.id}", read_token)

      expect(body.dig('data', 'roles')).to eq(['First Party'])
      expect(body.dig('data', 'fields').first).to include('name', 'type', 'role' => 'First Party')
      expect(body.dig('data', 'version')).to match(/\A\h{16}\z/)
    end

    it 'lists documents with JSON filters, q and fields, only in the person account' do
      mine = create(:submission, :with_submitters, template: mid_template, created_by_user: user)
      mine.submitters.first.update!(email: 'signer@example.com')
      done = create(:submission, :with_submitters, template: old_template, created_by_user: user,
                                                   completed_at: Time.current)
      other_template = create(:template, account: other_account, author: other_user)
      create(:submission, :with_submitters, template: other_template, created_by_user: other_user)

      body = get_json('/gxb/v1/documents', read_token)
      expect(body['data'].pluck('id')).to contain_exactly(mine.id, done.id)

      body = get_json('/gxb/v1/documents', read_token,
                      filter: { and: [{ field: 'status', op: 'eq', value: 'completed' }] }.to_json)
      expect(body['data'].pluck('id')).to eq([done.id])
      expect(body['data'].first['status']).to eq('completed')

      body = get_json('/gxb/v1/documents', read_token, q: 'signer@example', fields: %w[template_name].to_json)
      expect(body['data']).to eq([{ 'id' => mine.id, 'template_name' => 'Alpha NDA' }])

      get_json('/gxb/v1/documents', read_token, filter: { and: [{ field: 'status', op: 'eq', value: 'x' }] }.to_json)
      expect_error(422)
    end

    describe 'template.create with an Idempotency-Key' do
      it 'makes one template for two calls with the same key, and refuses the key with other arguments' do
        token = token_for
        expect do
          post_json('/gxb/v1/templates', token, { name: 'Once' }, 'Idempotency-Key' => 'k-1')
          expect(response).to have_http_status(:created)
          first_id = response.parsed_body.dig('data', 'id')

          post_json('/gxb/v1/templates', token, { name: 'Once' }, 'Idempotency-Key' => 'k-1')
          expect(response).to have_http_status(:created)
          expect(response.parsed_body.dig('data', 'id')).to eq(first_id)
        end.to change(Template, :count).by(1)

        post_json('/gxb/v1/templates', token, { name: 'Other' }, 'Idempotency-Key' => 'k-1')
        expect_error(422, 'idempotency_key_reused')
        expect(GxbApiIdempotencyKey.last.key_digest).to eq(Digest::SHA256.hexdigest('k-1'))
      end

      it 'frees the key after a clean refusal and refuses unknown arguments' do
        token = token_for
        post_json('/gxb/v1/templates', token, { name: 'X', color: 'red' }, 'Idempotency-Key' => 'k-2')
        expect_error(422, 'invalid_arguments')
        expect(GxbApiIdempotencyKey.count).to eq(0)

        post '/gxb/v1/templates', params: '{bad', headers: bearer(token, 'Content-Type' => 'application/json')
        expect_error(400, 'bad_json')
      end
    end

    describe 'signature requests' do
      let(:submitters) { [{ email: 'Signer@Example.com', name: 'Signer', role: 'First Party' }] }

      before do
        ActionMailer::Base.deliveries.clear
        SendSubmitterInvitationEmailJob.clear
      end

      def preview(token = read_token, list = submitters, template = mid_template)
        get_json('/gxb/v1/signature_requests/preview', token, template_id: template.id, submitters: list.to_json)
      end

      it 'previews the exact recipients and template version, and saves and sends nothing' do
        expect do
          body = preview
          expect(response).to have_http_status(:ok)
          expect(body['data']).to include('template_id' => mid_template.id, 'emails_to' => ['signer@example.com'],
                                          'template_version' => match(/\A\h{16}\z/))
          expect(body.dig('data', 'submitters')).to eq([{ 'email' => 'signer@example.com', 'name' => 'Signer',
                                                          'phone' => nil, 'role' => 'First Party',
                                                          'status' => 'not_sent' }])
          expect(body.dig('data', 'confirmation')).to match(/\A\h{32}\z/)
        end.not_to(change { table_counts })
        expect(SendSubmitterInvitationEmailJob.jobs).to be_empty

        preview(read_token, [{ email: 'x@example.com', role: 'Nobody' }])
        expect_error(422)
        preview(read_token, [{ name: 'no email' }])
        expect_error(422)
      end

      it 'sends only with the confirmation for the same template version and submitters, once per key' do
        confirmation = preview.dig('data', 'confirmation')
        token = token_for
        args = { template_id: mid_template.id, submitters:, confirmation: }

        expect do
          post_json('/gxb/v1/signature_requests', token, args.merge(confirmation: 'wrong'))
          expect_error(409, 'confirmation_mismatch')
          post_json('/gxb/v1/signature_requests', token,
                    args.merge(submitters: [{ email: 'someone.else@example.com', role: 'First Party' }]))
          expect_error(409)
        end.not_to change(Submission, :count)

        expect do
          post_json('/gxb/v1/signature_requests', token, args, 'Idempotency-Key' => 'send-1')
          expect(response).to have_http_status(:created)
          post_json('/gxb/v1/signature_requests', token, args, 'Idempotency-Key' => 'send-1')
          expect(response).to have_http_status(:created)
        end.to change(Submission, :count).by(1)

        submission = Submission.find(response.parsed_body.dig('data', 'id'))
        expect(submission.account_id).to eq(account.id)
        expect(response.parsed_body.dig('data', 'template_id')).to eq(mid_template.id)

        expect(SendSubmitterInvitationEmailJob.jobs.size).to eq(1)
        SendSubmitterInvitationEmailJob.drain
        expect(ActionMailer::Base.deliveries.flat_map(&:to)).to eq(['signer@example.com'])
      end

      it 'refuses a send after the template changed since the preview' do
        confirmation = preview.dig('data', 'confirmation')
        mid_template.update!(name: 'Alpha NDA v2')

        expect do
          post_json('/gxb/v1/signature_requests', token_for,
                    { template_id: mid_template.id, submitters:, confirmation: })
        end.not_to change(Submission, :count)
        expect_error(409, 'confirmation_mismatch')
      end
    end
  end

  describe 'two first calls at the same time' do
    self.use_transactional_tests = false

    after do
      User.where(auth_uid: 'sub-race').find_each do |raced|
        owner = raced.account
        raced.delete
        owner.delete
      end
      user.delete
      account.delete
    end

    it 'makes one account' do
      person = { 'sub' => 'sub-race', 'email' => 'race@example.com', 'name' => 'Race Person' }
      barrier = Concurrent::CyclicBarrier.new(2)
      allow(Account).to receive(:create!).and_wrap_original do |original, **attrs|
        barrier.wait(5) # both calls passed the lookup and now insert at the same time
        original.call(**attrs)
      end

      accounts_before = Account.count
      results = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { GxbApiAccounts.find_or_create!(claims(person)).id }
        end
      end.map(&:value)

      expect(results.uniq.size).to eq(1)
      expect(User.where(auth_uid: 'sub-race').count).to eq(1)
      expect(Account.count).to eq(accounts_before + 1)
    end
  end
end
