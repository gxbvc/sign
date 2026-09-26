# frozen_string_literal: true

# GXB: staff sign in only with GXB (auth.gxb.vc). The upstream password and two-factor form specs are replaced
# because that form no longer exists. spec/requests/gxb_sso_spec.rb covers the full flow.
RSpec.describe 'Sign In' do
  let(:account) { create(:account) }
  let!(:user) { create(:user, account:, email: 'john.dou@example.com', password: 'strong_password') }

  it 'has no password form when GXB sign-in is not configured' do
    visit new_user_session_path

    expect(page).to have_content('GXB sign-in is not configured')
    expect(page).to have_no_field('Password')
    expect(page).to have_no_content('Document Templates')
  end

  it 'sends a password reset link to GXB sign-in' do
    token = user.send(:set_reset_password_token)

    visit edit_user_password_path(reset_password_token: token)

    expect(page).to have_content('GXB sign-in is not configured')
    expect(page).to have_no_field('Password')
  end
end
