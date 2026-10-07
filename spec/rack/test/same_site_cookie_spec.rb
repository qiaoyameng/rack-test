# frozen_string_literal: true

require_relative '../../spec_helper'

describe 'SameSite cookies' do
  def context(top_level_site:, initiator_site:, method:, top_level_navigation: false, **options)
    Rack::Test::BrowserContext.new(
      top_level_site: top_level_site,
      initiator_site: initiator_site,
      request_method: method,
      top_level_navigation: top_level_navigation,
      **options
    )
  end

  def cookie(attribute)
    Rack::Test::Cookie.new(
      "cookie=#{attribute}; path=/; secure; samesite=#{attribute}",
      URI('https://target.test/')
    )
  end

  def jar(*cookies, default_same_site: nil, resolver: Rack::Test::RegistrableDomainResolver)
    Rack::Test::CookieJar.new(
      cookies,
      'target.test',
      default_same_site: default_same_site,
      registrable_domain_resolver: resolver
    )
  end

  it 'sends all SameSite policies to same-site subresource requests' do
    browser = context(
      top_level_site: 'https://target.test',
      initiator_site: 'https://target.test',
      method: 'POST'
    )
    cookie_jar = jar(cookie('strict'), cookie('lax'), cookie('none'))

    cookie_jar.for(URI('https://target.test/'), browser).
      must_equal 'cookie=strict; cookie=lax; cookie=none'
  end

  it 'withholds Strict and Lax cookies from cross-site POST requests' do
    browser = context(
      top_level_site: 'https://source.test',
      initiator_site: 'https://source.test',
      method: 'POST'
    )
    cookie_jar = jar(cookie('strict'), cookie('lax'), cookie('none'))

    cookie_jar.for(URI('https://target.test/'), browser).
      must_equal 'cookie=none'
  end

  it 'sends only Lax and None cookies on cross-site top-level GET navigations' do
    browser = context(
      top_level_site: 'https://source.test',
      initiator_site: 'https://source.test',
      method: 'GET',
      top_level_navigation: true
    )
    cookie_jar = jar(cookie('strict'), cookie('lax'), cookie('none'))

    cookie_jar.for(URI('https://target.test/'), browser).
      must_equal 'cookie=lax; cookie=none'
  end

  it 'withholds Lax cookies from unsafe cross-site top-level navigations' do
    browser = context(
      top_level_site: 'https://source.test',
      initiator_site: 'https://source.test',
      method: 'POST',
      top_level_navigation: true
    )
    cookie_jar = jar(cookie('lax'), cookie('none'))

    cookie_jar.for(URI('https://target.test/'), browser).
      must_equal 'cookie=none'
  end

  it 'compares the target and browser sites including scheme' do
    browser = context(
      top_level_site: 'https://target.test',
      initiator_site: 'https://target.test',
      method: 'GET',
      top_level_navigation: true
    )
    cookie_jar = jar(cookie('lax'))

    cookie_jar.for(URI('http://target.test/'), browser).must_equal ''
  end

  it 'requires both top-level and initiator sites to be same-site for Strict' do
    browser = context(
      top_level_site: 'https://target.test',
      initiator_site: 'https://source.test',
      method: 'GET'
    )
    cookie_jar = jar(cookie('strict'), cookie('lax'))

    cookie_jar.for(URI('https://target.test/'), browser).must_equal ''
  end

  it 'continues to require Secure, Domain, and Path filters to match' do
    browser = context(
      top_level_site: 'https://target.test',
      initiator_site: 'https://target.test',
      method: 'GET'
    )
    path_cookie = Rack::Test::Cookie.new(
      'path=1; path=/admin; secure; samesite=strict',
      URI('https://target.test/admin')
    )
    domain_cookie = Rack::Test::Cookie.new(
      'domain=1; path=/; secure; samesite=strict',
      URI('https://target.test/')
    )
    secure_cookie = cookie('strict')

    cookie_jar = jar(path_cookie, domain_cookie, secure_cookie)

    cookie_jar.for(URI('https://target.test/other'), browser).
      must_equal 'cookie=strict; domain=1'
    cookie_jar.for(URI('https://www.target.test/'), browser).
      must_equal ''
    cookie_jar.for(URI('http://target.test/'), browser).must_equal ''
  end

  it 'uses the injected resolver when determining the registrable domain' do
    resolver = ->(host) { host.split('.').last(3).join('.') }
    browser = context(
      top_level_site: 'https://source.example.co.uk',
      initiator_site: 'https://source.example.co.uk',
      method: 'POST',
      registrable_domain_resolver: resolver
    )
    cookie_jar = jar(cookie('strict'), resolver: resolver)

    cookie_jar.for(URI('https://target.example.co.uk/'), browser).
      must_equal ''
  end

  it 'requires the default policy to be explicit for cookies without SameSite' do
    browser = context(
      top_level_site: 'https://source.test',
      initiator_site: 'https://source.test',
      method: 'POST'
    )
    unspecified = Rack::Test::Cookie.new(
      'unspecified=1; path=/; secure',
      URI('https://target.test/')
    )

    proc { jar(unspecified).for(URI('https://target.test/'), browser) }.
      must_raise ArgumentError
  end

  it 'applies the explicitly configured default policy to cookies without SameSite' do
    browser = context(
      top_level_site: 'https://source.test',
      initiator_site: 'https://source.test',
      method: 'POST'
    )
    unspecified = Rack::Test::Cookie.new(
      'unspecified=1; path=/; secure',
      URI('https://target.test/')
    )

    jar(unspecified, default_same_site: 'lax').
      for(URI('https://target.test/'), browser).must_equal ''

    browser = context(
      top_level_site: 'https://source.test',
      initiator_site: 'https://source.test',
      method: 'GET',
      top_level_navigation: true
    )

    jar(unspecified, default_same_site: 'lax').
      for(URI('https://target.test/'), browser).must_equal 'unspecified=1'
  end

  it 'rejects SameSite=None cookies without Secure when browser context is enabled' do
    cookie_jar = Rack::Test::CookieJar.new([], 'target.test')
    cookie_jar.merge('none=1; path=/; samesite=none', URI('https://target.test/'))
    cookie_jar['none'].must_equal '1'

    browser = context(
      top_level_site: 'https://target.test',
      initiator_site: 'https://target.test',
      method: 'GET'
    )
    cookie_jar.merge(
      'browser_none=1; path=/; samesite=none',
      URI('https://target.test/'),
      browser
    )

    cookie_jar['browser_none'].must_be_nil
  end

  it 'keeps ignoring SameSite rules without browser context' do
    cookie_jar = jar(cookie('strict'))

    cookie_jar.for(URI('https://target.test/')).must_equal 'cookie=strict'
  end
end
