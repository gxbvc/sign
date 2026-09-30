# frozen_string_literal: true

# Included in Template by config/initializers/field_guard_gxb.rb. See GxbFieldGuard.
module GxbTemplateFields
  extend ActiveSupport::Concern

  included do
    before_validation { self.fields = GxbFieldGuard.normalize(fields) }
    validate :gxb_field_types
  end

  private

  def gxb_field_types
    GxbFieldGuard.type_problems(fields).each { |problem| errors.add(:base, problem) }
  end
end
