# frozen-string-literal: true

require_relative '../../spec_helper'

describe Rack::Test::BrowserContext do
  def context(**options)
    Rack::Test::BrowserContext.new(
      **{top_level_site: 'https://a.test', default_same_site: :lax}.merge(options)
    )
  end

  def cookie(header)
    Rack::Test::Cookie.new(header, URI('https://b.test/'))
  end

  it 'requires an explicit default policy for cookies without SameSite' do
    lambda do
      Rack::Test::BrowserContext.new(top_level_site: 'https://a.test')
    end.must_raise ArgumentError

    lambda do
      context(default_same_site: :sometimes)
    end.must_raise ArgumentError
  end

  it 'compares sites including the scheme' do
    cross_scheme = context(initiator_site: 'http://b.test')
    same_scheme = context(initiator_site: 'https://b.test')
    target = URI('https://b.test/')

    cross_scheme.send_cookie?(cookie('n=1; SameSite=None; Secure'), target).must_equal true
    cross_scheme.send_cookie?(cookie('s=1; SameSite=Strict'), target).must_equal false
    same_scheme.send_cookie?(cookie('s=1; SameSite=Strict'), target).must_equal true
  end

  it 'treats subdomains and other ports of the same site as same-site' do
    ctx = context(initiator_site: 'https://www.b.test')
    ctx.send_cookie?(cookie('s=1; SameSite=Strict'), URI('https://api.b.test:8443/x')).must_equal true
  end

  it 'allows injecting a custom registrable domain resolver' do
    resolver = Object.new
    def resolver.registrable_domain(host)
      host.end_with?('.co.uk') ? host.split('.').last(3).join('.') : host.split('.').last(2).join('.')
    end

    ctx = context(initiator_site: 'https://a.co.uk', resolver: resolver)
    ctx.send_cookie?(cookie('s=1; SameSite=Strict'), URI('https://b.co.uk/')).must_equal false

    default_ctx = context(initiator_site: 'https://a.co.uk')
    default_ctx.send_cookie?(cookie('s=1; SameSite=Strict'), URI('https://b.co.uk/')).must_equal true
  end

  it 'sends Strict cookies only when the initiator is same-site' do
    strict = cookie('s=1; SameSite=Strict')
    target = URI('https://b.test/')

    context(initiator_site: 'https://b.test').send_cookie?(strict, target).must_equal true
    context(initiator_site: 'https://a.test', top_level_navigation: true).
      send_cookie?(strict, target).must_equal false
  end

  it 'sends Lax cookies cross-site only for safe top-level navigations' do
    lax = cookie('l=1; SameSite=Lax')
    target = URI('https://b.test/')

    context(initiator_site: 'https://a.test', top_level_navigation: true, method: 'GET').
      send_cookie?(lax, target).must_equal true
    context(initiator_site: 'https://a.test', top_level_navigation: true, method: 'POST').
      send_cookie?(lax, target).must_equal false
    context(initiator_site: 'https://a.test', top_level_navigation: false, method: 'GET').
      send_cookie?(lax, target).must_equal false
  end

  it 'sends None cookies cross-site regardless of navigation type' do
    none = cookie('n=1; SameSite=None; Secure')
    target = URI('https://b.test/')

    context(initiator_site: 'https://a.test', method: 'POST').
      send_cookie?(none, target).must_equal true
  end

  it 'applies the configured default policy to cookies without SameSite' do
    plain = cookie('p=1')
    target = URI('https://b.test/')

    context(initiator_site: 'https://a.test', default_same_site: :none).
      send_cookie?(plain, target).must_equal true
    context(initiator_site: 'https://a.test', default_same_site: :strict).
      send_cookie?(plain, target).must_equal false
    context(initiator_site: 'https://a.test', default_same_site: :lax,
            top_level_navigation: true, method: 'GET').
      send_cookie?(plain, target).must_equal true
  end

  it 'rejects SameSite=None cookies without the Secure attribute' do
    ctx = context
    ctx.acceptable_cookie?(cookie('n=1; SameSite=None')).must_equal false
    ctx.acceptable_cookie?(cookie('n=1; SameSite=None; Secure')).must_equal true
    ctx.acceptable_cookie?(cookie('l=1; SameSite=Lax')).must_equal true
  end

  it 'returns a copy with a different request method for redirect hops' do
    ctx = context(method: 'POST', top_level_navigation: true)
    get_ctx = ctx.with_method('GET')

    get_ctx.method.must_equal 'GET'
    ctx.method.must_equal 'POST'
    get_ctx.top_level_site.must_equal ctx.top_level_site
    get_ctx.initiator_site.must_equal ctx.initiator_site
    get_ctx.top_level_navigation?.must_equal true
  end
end
