# frozen_string_literal: true

require_relative '../../spec_helper'

describe Rack::Test::BrowserContext do
  it 'builds sites with scheme and registrable domain' do
    context = Rack::Test::BrowserContext.new(
      top_level_site: 'https://www.example.co.uk',
      initiator_site: 'https://shop.example.co.uk',
      registrable_domain_resolver: ->(host) { host.split('.').last(3).join('.') }
    )

    context.top_level_site.must_equal Rack::Test::Site.new('https', 'example.co.uk')
    context.initiator_site.must_equal Rack::Test::Site.new('https', 'example.co.uk')
  end

  it 'ignores ports when comparing sites' do
    context = Rack::Test::BrowserContext.new(
      top_level_site: 'https://example.com:4000',
      initiator_site: 'https://example.com:4000'
    )

    context.same_site_request?(context.site_for(URI('https://www.example.com:8443/path'))).
      must_equal true
  end

  it 'includes scheme in site comparison' do
    context = Rack::Test::BrowserContext.new(
      top_level_site: 'https://example.com',
      initiator_site: 'https://example.com'
    )

    context.same_site_request?(context.site_for(URI('http://example.com/path'))).
      must_equal false
  end

  it 'preserves the navigation context when changing the request method' do
    context = Rack::Test::BrowserContext.new(
      top_level_site: 'https://shop.test',
      initiator_site: 'https://shop.test',
      top_level_navigation: true,
      request_method: 'POST'
    )

    redirected = context.for_request('GET')

    redirected.request_method.must_equal 'GET'
    redirected.top_level_navigation?.must_equal true
    redirected.top_level_site.must_equal context.top_level_site
    redirected.initiator_site.must_equal context.initiator_site
    context.request_method.must_equal 'POST'
  end

  it 'copies all navigation state' do
    context = Rack::Test::BrowserContext.new(
      top_level_site: 'https://shop.test',
      initiator_site: 'https://shop.test',
      top_level_navigation: true,
      request_method: 'POST',
      default_same_site: 'lax'
    )

    copy = context.dup

    copy.initiator_site.must_equal context.initiator_site
    copy.top_level_navigation?.must_equal true
    copy.default_same_site.must_equal 'lax'
    copy.request_method.must_equal 'POST'
  end

  it 'keeps an explicitly configured resolver and default policy' do
    resolver = ->(host) { host.split('.').last(3).join('.') }
    context = Rack::Test::BrowserContext.new(
      top_level_site: 'https://shop.example.co.uk',
      initiator_site: 'https://shop.example.co.uk',
      default_same_site: 'strict',
      registrable_domain_resolver: resolver
    )

    wrapped = Rack::Test::BrowserContext.wrap(
      context,
      'GET',
      'lax',
      Rack::Test::RegistrableDomainResolver
    )

    wrapped.registrable_domain_resolver.must_equal resolver
    wrapped.default_same_site.must_equal 'strict'
    wrapped.top_level_site.must_equal Rack::Test::Site.new('https', 'example.co.uk')
  end
end

describe Rack::Test::RegistrableDomainResolver do
  it 'uses the final two labels for ordinary domains' do
    Rack::Test::RegistrableDomainResolver.call('www.example.com').must_equal 'example.com'
  end

  it 'keeps single label hosts and IPv4 addresses unchanged' do
    Rack::Test::RegistrableDomainResolver.call('localhost').must_equal 'localhost'
    Rack::Test::RegistrableDomainResolver.call('127.0.0.1').must_equal '127.0.0.1'
  end
end
