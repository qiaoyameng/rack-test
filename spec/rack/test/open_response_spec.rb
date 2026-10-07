# frozen-string-literal: true

require_relative '../../spec_helper'

describe 'Rack::Test::Session#open_response' do
  # A response body that can only be enumerated once, and records how
  # often it was enumerated and closed. Optionally raises while
  # producing the chunk at the given index.
  class OneShotBody
    attr_reader :each_calls, :close_count

    def initialize(chunks, fail_at: nil)
      @chunks = chunks
      @fail_at = fail_at
      @each_calls = 0
      @close_count = 0
    end

    def each
      @each_calls += 1
      raise 'body enumerated more than once' if @each_calls > 1

      @chunks.each_with_index do |chunk, index|
        raise 'chunk read failure' if @fail_at == index

        yield chunk
      end
    end

    def close
      @close_count += 1
    end
  end

  def streaming_session(body, status: 200, headers: {})
    Rack::Test::Session.new(lambda { |_env| [status, headers, body] })
  end

  it 'exposes status and headers before the body is consumed' do
    body = OneShotBody.new(%w[chunk1 chunk2])
    streaming_session(body, status: 201, headers: { 'x-stream' => 'yes' }).open_response('/stream') do |response|
      response.status.must_equal 201
      response.headers.must_equal('x-stream' => 'yes')
      body.each_calls.must_equal 0
    end
  end

  it 'supports pausing and resuming chunk reads with a one-shot body' do
    body = OneShotBody.new(%w[chunk1 chunk2 chunk3])
    streaming_session(body).open_response('/stream') do |response|
      response.read_chunk.must_equal 'chunk1'
      body.each_calls.must_equal 1
      response.body.must_equal 'chunk1'

      response.read_chunk.must_equal 'chunk2'
      response.read_chunk.must_equal 'chunk3'
      response.read_chunk.must_be_nil
      response.body.must_equal 'chunk1chunk2chunk3'
      body.each_calls.must_equal 1
    end
    body.close_count.must_equal 1
  end

  it 'yields remaining chunks via each_chunk' do
    body = OneShotBody.new(%w[a b])
    streaming_session(body).open_response('/stream') do |response|
      response.read_chunk.must_equal 'a'
      response.each_chunk.to_a.must_equal %w[b]
      response.must_be :closed?
    end
  end

  it 'closes the body once when the block exits' do
    body = OneShotBody.new(%w[a b])
    response = streaming_session(body).open_response('/stream') { |r| r.each_chunk { } }
    response.must_be :closed?
    body.close_count.must_equal 1
  end

  it 'closes the body once when the test raises inside the block' do
    body = OneShotBody.new(%w[a b])
    error = proc do
      streaming_session(body).open_response('/stream') do |response|
        response.read_chunk
        raise 'test failure'
      end
    end.must_raise(RuntimeError)
    error.message.must_equal 'test failure'
    body.close_count.must_equal 1
  end

  it 'closes the body once when stopped early via close' do
    body = OneShotBody.new(%w[a b c])
    streaming_session(body).open_response('/stream') do |response|
      response.read_chunk.must_equal 'a'
      response.close
      response.close
      response.must_be :closed?
      response.read_chunk.must_be_nil
    end
    body.each_calls.must_equal 1
    body.close_count.must_equal 1
  end

  it 'keeps received chunks and headers when reading a chunk fails' do
    body = OneShotBody.new(%w[a b c], fail_at: 1)
    headers = { 'x-stream' => 'yes' }
    streaming_session(body, headers: headers).open_response('/stream') do |response|
      response.read_chunk.must_equal 'a'
      error = proc { response.read_chunk }.must_raise(RuntimeError)
      error.message.must_equal 'chunk read failure'

      response.must_be :closed?
      response.status.must_equal 200
      response.headers.must_equal headers
      response.body.must_equal 'a'
      response.read_chunk.must_be_nil
    end
    body.close_count.must_equal 1
  end

  it 'distinguishes application failure before a response is generated' do
    session = Rack::Test::Session.new(lambda { |_env| raise 'app failure' })
    after_request_calls = 0
    session.after_request { after_request_calls += 1 }

    error = proc { session.open_response('/stream') }.must_raise(RuntimeError)
    error.message.must_equal 'app failure'
    proc { session.last_response }.must_raise(Rack::Test::Error)
    after_request_calls.must_equal 0
  end

  it 'merges cookies as soon as headers are available' do
    body = OneShotBody.new(%w[a])
    headers = { 'set-cookie' => 'streamed=1;' }
    session = streaming_session(body, headers: headers)
    session.open_response('/stream') do |response|
      body.each_calls.must_equal 0
      session.cookie_jar['streamed'].must_equal '1'
      response.read_chunk
    end
  end

  it 'runs after_request callbacks exactly once, when the response is closed' do
    body = OneShotBody.new(%w[a])
    session = streaming_session(body)
    after_request_calls = 0
    session.after_request { after_request_calls += 1 }

    session.open_response('/stream') do |response|
      after_request_calls.must_equal 0
      response.read_chunk.must_equal 'a'
      after_request_calls.must_equal 0
      response.read_chunk.must_be_nil
      response.must_be :closed?
      after_request_calls.must_equal 1
    end
    after_request_calls.must_equal 1
  end

  it 'runs after_request callbacks exactly once when the test raises' do
    body = OneShotBody.new(%w[a b])
    session = streaming_session(body)
    after_request_calls = 0
    session.after_request { after_request_calls += 1 }

    proc { session.open_response('/stream') { raise 'test failure' } }.must_raise(RuntimeError)
    after_request_calls.must_equal 1
  end

  it 'does not allow a second open response to overwrite an unclosed one' do
    session = Rack::Test::Session.new(lambda { |_env| [200, {}, OneShotBody.new(%w[a])] })
    first = session.open_response('/stream')

    error = proc { session.open_response('/stream') }.must_raise(Rack::Test::Error)
    error.message.must_include 'open response'
    session.last_response.must_be_same_as first

    first.close
    second = session.open_response('/stream')
    session.last_response.must_be_same_as second
    second.close
  end

  it 'returns the open response and requires explicit close without a block' do
    body = OneShotBody.new(%w[a b])
    session = streaming_session(body)
    response = session.open_response('/stream')

    response.must_be_instance_of Rack::Test::OpenResponse
    session.last_response.must_be_same_as response
    response.read_chunk.must_equal 'a'
    response.close
    response.must_be :closed?
    body.close_count.must_equal 1
  end

  it 'records the last request' do
    session = streaming_session(OneShotBody.new([]))
    session.open_response('/stream', method: 'POST') { }
    session.last_request.env['REQUEST_METHOD'].must_equal 'POST'
  end

  it 'is delegated through Rack::Test::Methods' do
    open_response('/') do |response|
      response.status.must_equal 200
      response.each_chunk.to_a.join.must_equal last_response.body
    end
  end
end
