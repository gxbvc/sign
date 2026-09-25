# frozen_string_literal: true

describe User do
  describe '.find_or_provision_by_auth_claims' do
    let(:account) { create(:account) }
    let!(:admin) { create(:user, account:, email: 'admin@example.com') }

    it 'matches email case-insensitively and backfills auth_uid' do
      user = described_class.find_or_provision_by_auth_claims('sub' => 'uid-1', 'email' => ' ADMIN@Example.com ')

      expect(user).to eq(admin)
      expect(admin.reload.auth_uid).to eq('uid-1')
    end

    it 'prefers auth_uid over email' do
      other = create(:user, account:, email: 'other@example.com', auth_uid: 'uid-2')

      user = described_class.find_or_provision_by_auth_claims('sub' => 'uid-2', 'email' => admin.email)

      expect(user).to eq(other)
      expect(admin.reload.auth_uid).to be_nil
    end

    it 'raises on an email bound to another subject' do
      admin.update!(auth_uid: 'uid-1')

      expect do
        described_class.find_or_provision_by_auth_claims('sub' => 'uid-9', 'email' => admin.email)
      end.to raise_error(User::IdentityMismatch)

      expect(admin.reload.auth_uid).to eq('uid-1')
    end

    it 'provisions a @gxb.vc admin in the oldest active user account without a name' do
      create(:user, account: create(:account))

      user = described_class.find_or_provision_by_auth_claims('sub' => 'uid-3', 'email' => 'new@gxb.vc')

      expect(user).to be_persisted
      expect(user).to have_attributes(account:, role: User::ADMIN_ROLE, first_name: nil, last_name: nil)
      expect(user.valid_password?('password')).to be(false)
    end

    it 'refuses to provision when there is no active user' do
      admin.update!(archived_at: Time.current)

      expect(described_class.find_or_provision_by_auth_claims('sub' => 'uid-3', 'email' => 'new@gxb.vc')).to be_nil
    end

    it 'refuses missing claims, other domains, lookalike domains, and gxbot' do
      [
        nil,
        {},
        { 'sub' => '', 'email' => 'new@gxb.vc' },
        { 'sub' => 'uid-4', 'email' => 'new@example.org' },
        { 'sub' => 'uid-4', 'email' => 'new@notgxb.vc.example.org' },
        { 'sub' => 'uid-4', 'email' => 'gxbot@gxb.vc' }
      ].each do |claims|
        expect(described_class.find_or_provision_by_auth_claims(claims)).to be_nil
      end

      expect(described_class.count).to eq(1)
    end

    it 'never signs in an existing gxbot user' do
      create(:user, account:, email: 'gxbot@gxb.vc', auth_uid: 'uid-bot')

      expect(described_class.find_or_provision_by_auth_claims('sub' => 'uid-bot', 'email' => 'gxbot@gxb.vc')).to be_nil
    end

    it 'never signs in a gxbot user matched by auth_uid under another claim email' do
      create(:user, account:, email: 'gxbot@gxb.vc', auth_uid: 'uid-bot')

      expect(described_class.find_or_provision_by_auth_claims('sub' => 'uid-bot',
                                                              'email' => 'renamed@gxb.vc')).to be_nil
    end

    it 'does not rebind when another subject binds the row between lookup and backfill' do
      allow(described_class).to receive(:match_by_email!).and_wrap_original do |original, *args|
        original.call(*args).tap { |user| described_class.where(id: user.id).update_all(auth_uid: 'uid-first') }
      end

      expect do
        described_class.find_or_provision_by_auth_claims('sub' => 'uid-second', 'email' => admin.email)
      end.to raise_error(User::IdentityMismatch)

      expect(admin.reload.auth_uid).to eq('uid-first')
    end
  end
end
