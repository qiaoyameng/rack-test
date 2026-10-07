# frozen-string-literal: true

require_relative '../../spec_helper'

describe 'Rack::Test::Session#open_response' do
  # A response body whose +each+ can only be called once, that records
  # how often it is closed, and that can be told to raise while yielding
  # a given chunk.
  class SingleEachBody
    attr_reader :each_calls, :close_calls

    def initialize(chunks, raise_at: nil)
      @chunks = chunks
      @raise_at = raise_at
      @each_calls = 0
      @close_calls = 0
    end

    def each
      @each_calls += 1
      raise 'body each called more than once' if @each_calls > 1

      @chunks.each_with_index do |chunk, index|
        raise "read error at chunk #{index}" if index == @raise_at

        yield chunk
      end
    end

    def close
      @close_calls += 1
    end
  end

  def streaming_app(body, headers: {})
    lambda do |_env|
      [200, { 'content-type' => 'text/plain' }.merge(headers), body]
    end
  end

  def session_for(app)
    Rack::Test::Session.new(app)
  end

  it 'is delegated by Rack::Test::Methods' do
    open_response('/') do |response|
      response.status.must_equal 200
    end
    last_response.status.must_equal 200
  end

  it 'exposes status and headers before the body is consumed' do
    body = SingleEachBody.new(%w[a b c])
    session = session_for(streaming_app(body, headers: { 'x-stream' => 'yes' }))

    session.open_response('/stream') do |response|
      body.each_calls.must_equal 0
      response.status.must_equal 200
      response.headers['x-stream'].must_equal 'yes'
      response['content-type'].must_equal 'text/plain'
    end
  end

  it 'consumes the body chunk by chunk via read' do
    body = SingleEachBody.new(%w[a b c])
    session = session_for(streaming_app(body))

    session.open_response('/stream') do |response|
      response.read.must_equal 'a'
      response.read.must_equal 'b'
      response.read.must_equal 'c'
      response.read.must_be_nil
      response.chunks.must_equal %w[a b c]
      response.must_be :finished?
    end

    body.each_calls.must_equal 1
    body.close_calls.must_equal 1
  end

  it 'yields each chunk and closes the body once when fully consumed' do
    body = SingleEachBody.new(%w[a b c])
    session = session_for(streaming_app(body))
    received = []

    session.open_response('/stream') do |response|
      response.each { |chunk| received << chunk }
    end

    received.must_equal %w[a b c]
    body.close_calls.must_equal 1
  end

  it 'closes the body once when the block ends before the body is consumed' do
    body = SingleEachBody.new(%w[a b c])
    session = session_for(streaming_app(body))

    session.open_response('/stream') { |_response| nil }

    body.close_calls.must_equal 1
  end

  it 'closes the body once when the block raises' do
    body = SingleEachBody.new(%w[a b c])
    session = session_for(streaming_app(body))

    error = assert_raises(RuntimeError) do
      session.open_response('/stream') do |response|
        response.read.must_equal 'a'
        raise 'test failure'
      end
    end
    error.message.must_equal 'test failure'
    body.close_calls.must_equal 1
  end

  it 'closes the body once when the response is closed explicitly' do
    body = SingleEachBody.new(%w[a b c])
    session = session_for(streaming_app(body))

    session.open_response('/stream') do |response|
      response.read.must_equal 'a'
      response.close
      response.must_be :closed?
      response.read.must_be_nil
      response.close
    end

    body.close_calls.must_equal 1
  end

  it 'pauses and resumes iteration without re-enumerating the body' do
    body = SingleEachBody.new(%w[a b c])
    session = session_for(streaming_app(body))

    session.open_response('/stream') do |response|
      response.each do |chunk|
        chunk.must_equal 'a'
        break
      end
      response.read.must_equal 'b'
      response.each.to_a.must_equal %w[c]
    end

    body.each_calls.must_equal 1
    body.close_calls.must_equal 1
  end

  it 'keeps received chunks and headers when reading a chunk fails' do
    body = SingleEachBody.new(%w[a b c], raise_at: 1)
    session = session_for(streaming_app(body, headers: { 'x-stream' => 'yes' }))
    response = nil

    error = assert_raises(RuntimeError) do
      session.open_response('/stream') do |res|
        response = res
        res.each { |_| }
      end
    end

    error.message.must_equal 'read error at chunk 1'
    response.chunks.must_equal %w[a]
    response.headers['x-stream'].must_equal 'yes'
    response.must_be :closed?
    body.close_calls.must_equal 1
    session.last_response.must_be_same_as response
  end

  it 'does not touch last_response when the app fails before responding' do
    body = SingleEachBody.new(%w[ok])
    failing = lambda do |env|
      raise 'app boot failure' if env['PATH_INFO'] == '/fail'

      [200, {}, body]
    end
    session = session_for(failing)

    assert_raises(RuntimeError) { session.open_response('/fail') { } }
    assert_raises(Rack::Test::Error) { session.last_response }

    session.open_response('/') { }
    previous = session.last_response
    assert_raises(RuntimeError) { session.open_response('/fail') { } }
    session.last_response.must_be_same_as previous
  end

  it 'merges cookies as soon as the headers are available' do
    body = SingleEachBody.new(%w[a])
    app = streaming_app(body, headers: { 'set-cookie' => 'stream=1; path=/' })
    session = session_for(app)

    session.open_response('/stream') do |_response|
      body.each_calls.must_equal 0
      session.cookie_jar.get_cookie('stream').value.must_equal '1'
    end
  end

  it 'runs after_request callbacks once, when the headers are available' do
    body = SingleEachBody.new(%w[a b])
    session = session_for(streaming_app(body))
    calls = 0
    session.after_request { calls += 1 }

    session.open_response('/stream') do |response|
      calls.must_equal 1
      body.each_calls.must_equal 0
      response.each { |_| }
      calls.must_equal 1
    end

    calls.must_equal 1
  end

  it 'raises when opening a second response before closing the first' do
    body = SingleEachBody.new(%w[a b])
    session = session_for(streaming_app(body))

    session.open_response('/stream') do |response|
      error = assert_raises(Rack::Test::Error) do
        session.open_response('/stream') { }
      end
      error.message.must_include 'still open'
      session.last_response.must_be_same_as response
    end

    body.close_calls.must_equal 1
  end

  it 'allows a new open response after the previous one was closed' do
    bodies = [SingleEachBody.new(%w[a]), SingleEachBody.new(%w[b])]
    app = lambda do |_env|
      [200, {}, bodies.shift]
    end
    session = session_for(app)

    first = session.open_response('/stream') { |response| response.read }
    second = session.open_response('/stream') { |response| response.read }

    first.chunks.must_equal %w[a]
    second.chunks.must_equal %w[b]
    session.last_response.must_be_same_as second
  end

  it 'returns the open response for manual management without a block' do
    body = SingleEachBody.new(%w[a b])
    session = session_for(streaming_app(body))

    response = session.open_response('/stream')
    response.status.must_equal 200
    response.read.must_equal 'a'
    response.close
    body.close_calls.must_equal 1
    session.last_response.must_be_same_as response
  end

  it 'keeps the open response in last_response after the block' do
    body = SingleEachBody.new(%w[a b])
    session = session_for(streaming_app(body))
    response = session.open_response('/stream') { |res| res.read }

    session.last_response.must_be_same_as response
    session.last_response.chunks.must_equal %w[a]
    session.last_response.must_be :closed?
  end
end
