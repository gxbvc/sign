# frozen_string_literal: true

# Checks for template and submission field definitions, shared by GxbTemplateFields (Template) and
# GxbSubmissionFields (Submission). Every way to write fields (the editor, REST API, PDF tags, DocuSeal MCP, GXB
# Chat tools) ends in those two models, so a rule here holds for all of them.
#
# The signing form shows one step per field that is not read-only. A field the form cannot show, or that a signer
# can never fill, blocks the whole signing. That is how a raw `datenow` field (no form step, required) stopped a
# signer on 2026-09-30.
module GxbFieldGuard
  # Every type the signing form has a step or a display for (app/javascript/submission_form/form.vue and
  # template_builder/field_type.vue). `datenow` is not here: normalize turns it into a read-only date.
  TYPES = %w[
    text cells number date select radio multiple checkbox image file signature initials stamp payment phone
    verification kba heading strikethrough
  ].freeze

  # Read-only display types. They need no signer input and no default value.
  DISPLAY_TYPES = %w[heading strikethrough stamp].freeze
  CHOICE_TYPES = %w[select radio multiple].freeze
  DATE_FORMAT = 'MM/DD/YYYY'
  TODAY = '{{date}}'

  module_function

  # The editor makes the same conversion when a user adds a "Date signed" field. Fields made from PDF tags or the
  # API keep the raw `datenow` type, which the form does not know.
  def normalize(fields)
    return fields unless fields.is_a?(Array)

    fields.map do |field|
      next field unless field.is_a?(Hash) && field['type'] == 'datenow'

      field.merge('type' => 'date', 'readonly' => true, 'default_value' => TODAY,
                  'preferences' => (field['preferences'] || {}).reverse_merge('format' => DATE_FORMAT))
    end
  end

  # Always checked on save. Only the shape and the types, so a draft in the editor can still be saved.
  def type_problems(fields)
    return ['Fields must be a list'] unless fields.is_a?(Array)

    fields.flat_map.with_index do |field, index|
      next ["Field #{index + 1} must be an object"] unless field.is_a?(Hash)
      next [] if TYPES.include?(field['type'])

      ["#{label(field)} has type #{field['type'].inspect}, which the signing form cannot show. " \
       "Use one of: #{TYPES.join(', ')}. For the signing date, use a read-only date with default #{TODAY}"]
    end
  end

  # Checked when a submission is made or its fields change: a signer must be able to finish.
  def signable_problems(fields, submitters)
    problems = type_problems(fields)
    return problems unless problems.empty?

    submitter_uuids = Array(submitters).filter_map { |s| s['uuid'] if s.is_a?(Hash) }

    problems + duplicate_uuid_problems(fields) + fields.flat_map { |field| field_problems(field, submitter_uuids) }
  end

  def field_problems(field, submitter_uuids)
    problems = []

    unless DISPLAY_TYPES.include?(field['type']) || submitter_uuids.include?(field['submitter_uuid'])
      problems << "#{label(field)} belongs to no signer (submitter_uuid #{field['submitter_uuid'].inspect})"
    end

    if field['required'] && field['readonly'] && DISPLAY_TYPES.exclude?(field['type']) &&
       (field['default_value'].nil? || field['default_value'] == '')
      problems << "#{label(field)} is required and read-only with no default value, so nobody can fill it"
    end

    problems << "#{label(field)} has no options to choose from" if choice_without_options?(field)

    problems
  end

  def choice_without_options?(field)
    CHOICE_TYPES.include?(field['type']) &&
      Array(field['options']).none? { |option| option.is_a?(Hash) && option['value'].present? }
  end

  def duplicate_uuid_problems(fields)
    duplicates = fields.filter_map { |f| f['uuid'] }.tally.select { |_, count| count > 1 }.keys

    duplicates.map { |uuid| "Field uuid #{uuid} is used more than once" }
  end

  def label(field)
    name = field['name'].presence || field['uuid'].presence || 'unnamed'

    "Field #{name.to_s.inspect} (#{field['type'].inspect})"
  end
end
