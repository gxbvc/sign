# frozen_string_literal: true

require 'minitest/autorun'
require 'erb'
require 'json'
require 'cgi'

# Exercise presentation branches without loading the older checkout's Rails app.
class Object
  def presence
    self if present?
  end

  def present?
    !nil? && self != false && (!respond_to?(:empty?) || !empty?)
  end
end

module Docuseal
  def self.demo?
    false
  end
end

class BrandingTest < Minitest::Test
  ROOT = File.join(__dir__, 'branding')

  def render_file(path, content = {}, request_path: '/', devise: false)
    context = Object.new
    context.define_singleton_method(:content_for) { |key| content[key] }
    context.define_singleton_method(:root_url) { 'https://sign.gxb.vc/' }
    context.define_singleton_method(:request) { Struct.new(:path).new(request_path) }
    context.define_singleton_method(:devise_controller?) { devise }
    context.define_singleton_method(:render) { |*| '' }
    ERB.new(File.read(File.join(ROOT, path))).result(context.instance_eval { binding })
  end

  def test_metadata
    html = render_file('views/shared/_meta.html.erb')
    assert_includes html, 'content="GXB Sign"'
    assert_includes html, 'https://sign.gxb.vc/gxb-sign/og-image.png'
    assert_includes html, 'content="1200"'
    assert_includes html, 'content="630"'
    assert_includes html, 'summary_large_image'
    refute_includes html, '@docusealco'
    refute_includes html, 'noindex'
  end

  def test_document_title_and_noindex
    content = { html_title: 'Agreement | DocuSeal' }
    %w[views/shared/_meta.html.erb views/layouts/_head_tags.html.erb].each do |path|
      assert_includes render_file(path, content, request_path: '/s/example'), 'Agreement | GXB Sign'
    end
    assert_includes render_file('views/shared/_meta.html.erb', content, request_path: '/s/example'), 'noindex'
  end

  def test_private_preview_stays_disabled
    html = render_file('views/shared/_meta.html.erb', { disable_image_preview: true, preview_image_url: 'private.png' })
    assert_includes html, 'property="og:image" content=""'
    refute_includes html, 'private.png'
    refute_includes html, 'og-image.png'
  end

  def test_custom_preview_does_not_get_wrong_dimensions
    html = render_file('views/shared/_meta.html.erb', { preview_image_url: 'https://example.com/preview.png' })
    assert_includes html, 'https://example.com/preview.png'
    refute_includes html, 'og:image:width'
  end

  def test_manifest_and_image_dimensions
    manifest = JSON.parse(render_file('views/pwa/manifest.json.erb'))
    assert_equal 'GXB Sign', manifest.fetch('name')
    assert_equal 'GXB Sign', manifest.fetch('short_name')
    manifest.fetch('icons').each do |icon|
      assert File.file?(File.join(ROOT, 'public', File.basename(icon.fetch('src'))))
    end
    { 'og-image.png' => [1200, 630], 'apple-touch-icon.png' => [180, 180],
      'icon-192.png' => [192, 192], 'icon-512.png' => [512, 512],
      'favicon-16x16.png' => [16, 16], 'favicon-32x32.png' => [32, 32] }.each do |name, size|
      assert_equal size, File.binread(File.join(ROOT, 'public', name))[16, 8].unpack('NN'), name
    end
  end

  def test_footer_credits_docuseal_and_links_source
    html = File.read(File.join(ROOT, 'views/shared/_powered_by.html.erb'))
    assert_includes html, 'Based on'
    assert_includes html, 'Docuseal::GITHUB_URL'
    assert_includes html, '/gxb-sign/source.tar.gz'
    refute_match(/powered/i, html)
    assert File.file?(File.join(ROOT, 'LUCIDE-LICENSE'))
  end

  def test_vue_builder_logo_styles_are_loaded_and_scoped
    html = render_file('views/layouts/_head_tags.html.erb')
    assert_includes html, 'href="/gxb-sign/builder-branding-v1.css"'
    css = File.read(File.join(ROOT, 'public/builder-branding-v1.css'))
    assert_includes css, 'template-builder #title_container a[href="/"] > svg {'
    assert_includes css, 'url("/gxb-sign/favicon.svg")'
    assert_includes css, 'template-builder #title_container a[href="/"] > svg > *'
    assert_includes css, 'visibility: hidden'
  end

  def test_erb_syntax
    Dir[File.join(ROOT, 'views/**/*.erb')].each do |path|
      RubyVM::InstructionSequence.compile(ERB.new(File.read(path)).src)
    end
  end
end
