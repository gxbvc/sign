# frozen_string_literal: true

# Included in Submission by config/initializers/field_guard_gxb.rb. See GxbFieldGuard.
#
# A submission snapshots the template fields when its fields are customized. Without a snapshot it uses the
# template's own fields, which GxbTemplateFields has already checked for types.
module GxbSubmissionFields
  extend ActiveSupport::Concern

  included do
    before_validation { self.template_fields = GxbFieldGuard.normalize(template_fields) if template_fields }
    validate :gxb_signable_fields, if: -> { new_record? || template_fields_changed? }
  end

  private

  def gxb_signable_fields
    fields = template_fields || template&.fields
    return if fields.nil?

    submitters = template_submitters || template&.submitters

    GxbFieldGuard.signable_problems(fields, submitters).each { |problem| errors.add(:base, problem) }
  end
end
