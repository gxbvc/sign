# frozen_string_literal: true

describe User do
  describe '.find_or_provision_by_auth_claims' do
    let(:account) { create(:account) }
    let!(:admin) { create(:user, account:, email: 'admin@example.com') }
    let(:userinfo_url) { 'https://auth.gxb.vc/oauth/userinfo' }
    let(:access_token) { 'test-access-token-1' }

    # auth.gxb.vc GET /oauth/userinfo answers { sub, email, email_verified, staff, name }.
    def stub_staff(sub, staff: true)
      stub_request(:get, userinfo_url)
        .with(headers: { 'Authorization' => "Bearer #{access_token}" })
        .to_return(status: 200, body: { sub:, email: 'x@gxb.vc', email_verified: true, staff: }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    def resolve(sub, email, token: access_token)
      described_class.find_or_provision_by_auth_claims({ 'sub' => sub, 'email' => email }, access_token: token)
    end

    def expect_no_userinfo_call
      expect(a_request(:get, userinfo_url)).not_to have_been_made
    end

    it 'matches email case-insensitively and backfills auth_uid, with no userinfo call' do
      user = resolve('uid-1', ' ADMIN@Example.com ')

      expect(user).to eq(admin)
      expect(admin.reload.auth_uid).to eq('uid-1')
      expect_no_userinfo_call
    end

    it 'prefers auth_uid over email' do
      other = create(:user, account:, email: 'other@example.com', auth_uid: 'uid-2')

      user = resolve('uid-2', admin.email)

      expect(user).to eq(other)
      expect(admin.reload.auth_uid).to be_nil
      expect_no_userinfo_call
    end

    it 'signs in an existing @gxb.vc user, by auth_uid or by email, with no userinfo call' do
      by_uid = create(:user, account:, email: 'adrian@gxb.vc', auth_uid: 'uid-adrian')
      by_email = create(:user, account:, email: 'old@gxb.vc')

      expect(resolve('uid-adrian', 'renamed@gxb.vc')).to eq(by_uid)
      expect(resolve('uid-old', 'OLD@gxb.vc', token: nil)).to eq(by_email)
      expect(by_email.reload.auth_uid).to eq('uid-old')
      expect_no_userinfo_call
    end

    it 'raises on an email bound to another subject' do
      admin.update!(auth_uid: 'uid-1')

      expect { resolve('uid-9', admin.email) }.to raise_error(User::IdentityMismatch)

      expect(admin.reload.auth_uid).to eq('uid-1')
      expect_no_userinfo_call
    end

    it 'provisions a staff @gxb.vc admin in the oldest active user account without a name' do
      create(:user, account: create(:account))
      stub_staff('uid-3')

      user = resolve('uid-3', 'new@gxb.vc')

      expect(user).to be_persisted
      expect(user).to have_attributes(account:, email: 'new@gxb.vc', auth_uid: 'uid-3', role: User::ADMIN_ROLE,
                                      first_name: nil, last_name: nil)
      expect(user.valid_password?('password')).to be(false)
      expect(a_request(:get, userinfo_url).with(headers: { 'Authorization' => "Bearer #{access_token}" }))
        .to have_been_made.once
    end

    it 'asks userinfo with 5 second timeouts' do
      allow(Net::HTTP).to receive(:start).and_call_original
      stub_staff('uid-3')

      resolve('uid-3', 'new@gxb.vc')

      expect(Net::HTTP).to have_received(:start)
        .with('auth.gxb.vc', 443, hash_including(use_ssl: true, open_timeout: 5, read_timeout: 5))
    end

    it 'refuses to provision when there is no active user' do
      admin.update!(archived_at: Time.current)
      stub_staff('uid-3')

      expect(resolve('uid-3', 'new@gxb.vc')).to be_nil
    end

    it 'refuses a @gxb.vc address that Auth says is not staff' do
      allow(Rails.logger).to receive(:warn)

      { 'uid-a1' => 'adrian@gxb.vc', 'uid-a2' => 'Adrian+x@gxb.vc', 'uid-a3' => 'ADRIAN@GXB.VC' }.each do |sub, email|
        stub_staff(sub, staff: false)

        expect(resolve(sub, email)).to be_nil
      end

      expect(described_class.count).to eq(1)
      expect(described_class.where('LOWER(email) LIKE ?', 'adrian%')).to be_empty
      expect(Rails.logger).to have_received(:warn).with('GXB SSO staff check refused a new user: not_staff').thrice
    end

    {
      'a timeout' => [->(stub) { stub.to_timeout }, 'timeout'],
      'a connection error' => [->(stub) { stub.to_raise(Errno::ECONNREFUSED) }, 'network'],
      'HTTP 500' => [->(stub) { stub.to_return(status: 500, body: '{"sub":"uid-7","staff":true}') }, 'http_status'],
      'HTTP 401' => [->(stub) { stub.to_return(status: 401, body: '') }, 'http_status'],
      'bad JSON' => [->(stub) { stub.to_return(status: 200, body: '{"staff": tru') }, 'bad_json'],
      'a JSON array' => [->(stub) { stub.to_return(status: 200, body: '[true]') }, 'bad_json'],
      'a sub mismatch' => [{ sub: 'uid-other', staff: true }, 'sub_mismatch'],
      'a missing sub' => [{ staff: true }, 'sub_mismatch'],
      'a missing staff field' => [{ sub: 'uid-7' }, 'staff_missing'],
      'staff "true" as a string' => [{ sub: 'uid-7', staff: 'true' }, 'not_staff'],
      'staff 1' => [{ sub: 'uid-7', staff: 1 }, 'not_staff'],
      'staff null' => [{ sub: 'uid-7', staff: nil }, 'not_staff']
    }.each do |label, (answer, reason)|
      it "refuses a new @gxb.vc user on #{label}, and logs only the reason word" do
        allow(Rails.logger).to receive(:warn)
        stub = stub_request(:get, userinfo_url)
        answer.is_a?(Hash) ? stub.to_return(status: 200, body: answer.to_json) : answer.call(stub)

        expect(resolve('uid-7', 'new@gxb.vc')).to be_nil

        expect(described_class.count).to eq(1)
        expect(Rails.logger).to have_received(:warn).with("GXB SSO staff check refused a new user: #{reason}")
        expect(Rails.logger).not_to have_received(:warn).with(/test-access-token|new@gxb\.vc|uid-7/)
      end
    end

    it 'refuses a new @gxb.vc user with no access token, without calling userinfo' do
      expect(resolve('uid-7', 'new@gxb.vc', token: nil)).to be_nil
      expect(resolve('uid-7', 'new@gxb.vc', token: '')).to be_nil

      expect(described_class.count).to eq(1)
      expect_no_userinfo_call
    end

    it 'refuses missing claims, other domains, lookalike domains, and gxbot, even for staff' do
      stub_staff('uid-4')

      [
        nil,
        {},
        { 'sub' => '', 'email' => 'new@gxb.vc' },
        { 'sub' => 'uid-4', 'email' => 'new@example.org' },
        { 'sub' => 'uid-4', 'email' => 'new@notgxb.vc.example.org' },
        { 'sub' => 'uid-4', 'email' => 'gxbot@gxb.vc' }
      ].each do |claims|
        expect(described_class.find_or_provision_by_auth_claims(claims, access_token:)).to be_nil
      end

      expect(described_class.count).to eq(1)
      expect_no_userinfo_call
    end

    it 'does not even try to provision an email that is not one plain @gxb.vc mailbox' do
      allow(described_class).to receive(:create!).and_call_original
      stub_staff('uid-5')

      [
        'x@evil.com, y@gxb.vc',
        'x@evil.com,y@gxb.vc',
        "x@evil.com\ny@gxb.vc",
        'Y <y@gxb.vc>',
        'y@gxb.vc.evil.com',
        '=?utf-8?q?x=40evil.test=2c?=@gxb.vc',
        'x%40evil.test@gxb.vc',
        'x=y@gxb.vc',
        'x?y@gxb.vc',
        '"x"@gxb.vc'
      ].each do |email|
        expect(resolve('uid-5', email)).to be_nil
      end

      expect(described_class).not_to have_received(:create!)
      expect(described_class.count).to eq(1)
      expect_no_userinfo_call
    end

    it 'provisions an upper-case @GXB.VC staff email as the same lower-case address' do
      stub_staff('uid-6')

      user = resolve('uid-6', ' Y@GXB.VC ')

      expect(user).to have_attributes(email: 'y@gxb.vc', role: User::ADMIN_ROLE)
    end

    it 'provisions plus-tag, dotted and underscore staff mailboxes at gxb.vc' do
      ['first.last+tag@gxb.vc', 'a_b-c@gxb.vc'].each_with_index do |email, i|
        stub_staff("uid-t#{i}")

        user = resolve("uid-t#{i}", email)

        expect(user).to have_attributes(email:)
      end
    end

    it 'never signs in an existing gxbot user' do
      create(:user, account:, email: 'gxbot@gxb.vc', auth_uid: 'uid-bot')

      expect(resolve('uid-bot', 'gxbot@gxb.vc')).to be_nil
      expect_no_userinfo_call
    end

    it 'never signs in a gxbot user matched by auth_uid under another claim email' do
      create(:user, account:, email: 'gxbot@gxb.vc', auth_uid: 'uid-bot')

      expect(resolve('uid-bot', 'renamed@gxb.vc')).to be_nil
      expect_no_userinfo_call
    end

    it 'never signs in an archived user, even one Auth says is staff' do
      archived = create(:user, account:, email: 'gone@gxb.vc', auth_uid: 'uid-gone', archived_at: Time.current)
      stub_staff('uid-gone')

      expect(resolve('uid-gone', archived.email)).to be_nil
      expect(described_class.count).to eq(2)
      expect_no_userinfo_call
    end

    it 'does not rebind when another subject binds the row between lookup and backfill' do
      allow(described_class).to receive(:match_by_email!).and_wrap_original do |original, *args|
        original.call(*args).tap { |user| described_class.where(id: user.id).update_all(auth_uid: 'uid-first') }
      end

      expect { resolve('uid-second', admin.email) }.to raise_error(User::IdentityMismatch)

      expect(admin.reload.auth_uid).to eq('uid-first')
    end
  end
end
