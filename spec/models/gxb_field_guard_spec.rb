# frozen_string_literal: true

# GxbFieldGuard through Template (GxbTemplateFields) and Submission (GxbSubmissionFields), the two models every
# way of writing fields ends in.
describe GxbFieldGuard do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:submitter_uuid) { SecureRandom.uuid }
  let(:submitters) { [{ 'name' => 'Signer', 'uuid' => submitter_uuid }] }

  def field(overrides = {})
    { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => submitter_uuid, 'name' => 'Name', 'type' => 'text',
      'required' => true, 'preferences' => {}, 'areas' => [] }.merge(overrides)
  end

  def build_template(fields)
    Template.new(account:, author:, folder: account.default_template_folder, name: 'Agreement',
                 submitters:, fields:)
  end

  def build_submission(fields, template_submitters: submitters)
    Submission.new(account:, created_by_user: author, template: build_template([]), source: :api,
                   template_fields: fields, template_submitters:)
  end

  describe 'Template' do
    it 'turns a raw datenow field into a read-only date that fills in the signing day' do
      template = build_template([field('name' => 'Date', 'type' => 'datenow', 'preferences' => {})])

      expect(template.save).to be(true)
      expect(template.reload.fields.first).to include(
        'type' => 'date', 'readonly' => true, 'default_value' => '{{date}}',
        'preferences' => { 'format' => 'MM/DD/YYYY' }
      )
    end

    it 'keeps a date format that was already set on a datenow field' do
      template = build_template([field('type' => 'datenow', 'preferences' => { 'format' => 'DD/MM/YYYY' })])
      template.save!

      expect(template.reload.fields.first['preferences']).to eq('format' => 'DD/MM/YYYY')
    end

    it 'refuses a type the signing form cannot show, and names the field' do
      template = build_template([field('name' => 'Stamp duty', 'type' => 'dropdown')])

      expect(template.save).to be(false)
      expect(template.errors.full_messages.to_sentence).to include('"Stamp duty"', '"dropdown"', 'read-only date')
    end

    it 'refuses fields that are not a list of objects' do
      expect(build_template('text').save).to be(false)
      expect(build_template(['text']).save).to be(false)
    end

    it 'still saves an editor draft with a required select that has no options yet' do
      template = build_template([field('type' => 'select', 'options' => [{ 'uuid' => 'a', 'value' => '' }])])

      expect(template.save).to be(true)
    end

    it 'accepts every type the form can show' do
      fields = GxbFieldGuard::TYPES.map { |type| field('name' => type, 'type' => type) }

      expect(build_template(fields).save).to be(true)
    end

    it 'keeps every type that the template builder can add' do
      builder = Rails.root.join('app/javascript/template_builder/field_type.vue').read
      types = builder[/fieldNames \(\) \{\s*return \{(.*?)\n      \}/m, 1].scan(/^\s*(\w+):/).flatten - ['datenow']

      expect(types).to match_array(GxbFieldGuard::TYPES)
    end
  end

  describe 'Submission' do
    it 'normalizes a datenow field in the field snapshot' do
      submission = build_submission([field('type' => 'datenow')])

      expect(submission.save).to be(true)
      expect(submission.reload.template_fields.first).to include('type' => 'date', 'default_value' => '{{date}}')
    end

    it 'refuses a required read-only field with no value, which no signer can fill' do
      submission = build_submission([field('name' => 'Locked', 'readonly' => true)])

      expect(submission.save).to be(false)
      expect(submission.errors.full_messages.to_sentence).to include('"Locked"', 'nobody can fill it')
    end

    it 'accepts a required read-only field that has a default value' do
      expect(build_submission([field('readonly' => true, 'default_value' => 'Net 30')]).save).to be(true)
    end

    it 'accepts read-only headings and stamps with no default' do
      fields = [field('type' => 'heading', 'readonly' => true), field('type' => 'stamp', 'readonly' => true)]

      expect(build_submission(fields).save).to be(true)
    end

    it 'refuses a field that belongs to no signer' do
      submission = build_submission([field('name' => 'Orphan', 'submitter_uuid' => SecureRandom.uuid)])

      expect(submission.save).to be(false)
      expect(submission.errors.full_messages.to_sentence).to include('"Orphan"', 'belongs to no signer')
    end

    it 'refuses a choice field with no options to choose from' do
      submission = build_submission([field('name' => 'Plan', 'type' => 'select', 'options' => [{ 'value' => '' }])])

      expect(submission.save).to be(false)
      expect(submission.errors.full_messages.to_sentence).to include('"Plan"', 'no options')
    end

    it 'refuses two fields with the same uuid' do
      uuid = SecureRandom.uuid
      submission = build_submission([field('uuid' => uuid), field('uuid' => uuid, 'name' => 'Other')])

      expect(submission.save).to be(false)
      expect(submission.errors.full_messages.to_sentence).to include('used more than once')
    end

    it 'uses the template fields when there is no snapshot' do
      template = create(:template, account:, author:)
      template.update_column(:fields, [field('name' => 'Broken', 'type' => 'dropdown')])
      submission = Submission.new(account:, created_by_user: author, template: template.reload, source: :api)

      expect(submission.save).to be(false)
      expect(submission.errors.full_messages.to_sentence).to include('"Broken"')
    end

    it 'does not block an old submission that is saved again without a field change' do
      submission = build_submission([field]).tap(&:save!)
      submission.update_column(:template_fields, [field('readonly' => true)])

      expect(submission.reload.update(slug: SecureRandom.base58(14))).to be(true)
    end
  end
end
