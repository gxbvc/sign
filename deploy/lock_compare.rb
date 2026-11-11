# frozen_string_literal: true

require 'bundler'

# Read-only comparison of two Gemfile.lock texts (Bundler::LockfileParser; nothing is installed or resolved).
# The release check lets Gemfile.lock differ from the pinned upstream commit only when the gem NAMES, the gem platform
# variants, the SOURCES (rubygems.org only) and the PLATFORMS are identical. Only versions may change.
module LockCompare
  RUBYGEMS = 'https://rubygems.org'

  module_function

  def parse(text)
    Bundler::LockfileParser.new(text)
  end

  def rubygems?(source)
    source.is_a?(Bundler::Source::Rubygems)
  end

  def remotes(source)
    source.remotes.map { |remote| remote.to_s.chomp('/') }.sort
  end

  def describe(source)
    return "rubygems source #{remotes(source).join(', ')}" if rubygems?(source)

    "#{source.class.name.split('::').last.downcase} source #{source.respond_to?(:uri) ? source.uri : source}"
  end

  # Returns a list of problems, each naming the gem, source or platform. An empty list means "versions only".
  def problems(upstream_text, current_text)
    up = parse(upstream_text)
    cur = parse(current_text)
    list = source_problems(up, cur) + platform_problems(up, cur) + gem_problems(up, cur)
    list.uniq
  end

  # For a lock with no upstream twin (deploy/Gemfile.lock): only the source rule applies.
  def source_only_problems(text)
    non_rubygems_problems(parse(text))
  end

  def source_problems(up, cur)
    list = non_rubygems_problems(cur)
    up_remotes = up.sources.select { |source| rubygems?(source) }.flat_map { |source| remotes(source) }.uniq
    cur.sources.select { |source| rubygems?(source) }.flat_map { |source| remotes(source) }.uniq.each do |remote|
      list << "new source: #{remote}" unless up_remotes.include?(remote)
    end
    list
  end

  def non_rubygems_problems(parsed)
    parsed.sources.reject { |source| rubygems?(source) && remotes(source) == [RUBYGEMS] }.map do |source|
      "source is not rubygems.org only: #{describe(source)}"
    end
  end

  def platform_problems(up, cur)
    up_platforms = up.platforms.map(&:to_s)
    cur_platforms = cur.platforms.map(&:to_s)
    (cur_platforms - up_platforms).map { |platform| "new platform: #{platform}" } +
      (up_platforms - cur_platforms).map { |platform| "removed platform: #{platform}" }
  end

  def gem_problems(up, cur)
    up_names = up.specs.map(&:name).uniq
    cur_names = cur.specs.map(&:name).uniq
    list = (cur_names - up_names).map { |name| "new gem: #{name}" } +
           (up_names - cur_names).map { |name| "removed gem: #{name}" }
    up_variants = variants(up)
    cur_variants = variants(cur)
    (cur_names & up_names).sort.each do |name|
      (cur_variants[name] - up_variants[name]).each { |platform| list << "#{name}: new platform variant #{platform}" }
      (up_variants[name] - cur_variants[name]).each { |platform| list << "#{name}: removed platform variant #{platform}" }
    end
    list
  end

  def variants(parsed)
    parsed.specs.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |spec, result|
      result[spec.name] << spec.platform.to_s
    end.transform_values { |platforms| platforms.uniq.sort }
  end
end
