# frozen_string_literal: true

RSpec.describe 'Profile Settings' do
  let(:user) { create(:user, account: create(:account)) }

  before do
    sign_in(user)

    allow(Accounts).to receive(:can_send_emails?).and_return(true)

    visit settings_profile_index_path
  end

  it 'shows the profile settings page' do
    expect(page).to have_content('Profile')
    expect(page).to have_field('user[email]', with: user.email)
    expect(page).to have_field('user[first_name]', with: user.first_name)
    expect(page).to have_field('user[last_name]', with: user.last_name)

    # GXB: staff sign in only with GXB, so the password and two-factor settings are gone.
    expect(page).to have_no_content('Change Password')
    expect(page).to have_no_field('user[password]')
    expect(page).to have_no_content('Two-Factor Authentication')
  end

  context 'when changes contact information' do
    it 'updates first name, last name and email' do
      fill_in 'First name', with: 'Devid'
      fill_in 'Last name', with: 'Beckham'
      fill_in 'Email', with: 'david.beckham@example.com'

      all(:button, 'Update')[0].click

      user.reload

      expect(user.first_name).to eq('Devid')
      expect(user.last_name).to eq('Beckham')
      expect(user.email).to eq('david.beckham@example.com')
    end

    it 'does not update if email is invalid' do
      fill_in 'Email', with: 'devid+test@example'

      all(:button, 'Update')[0].click

      expect(page).to have_content('Email is invalid')
    end
  end
end
