require "uuid"
require "mutex"
require "protobuf"

require "./http2"

module GRPC
  class Server
    include HTTP2::Handler

    @services = Hash(String, Protobuf::Service).new

    def call(context : HTTP2::Server::Context)
      request, response = context.request, context.response

      if body = request.body
        compressed = body.read_bytes(UInt8) != 0
        length = body.read_bytes(UInt32, IO::ByteFormat::NetworkEndian)

        _, service_name, method_name = request.headers[":path"].split('/')
        service = @services[service_name]
        payload = service.handle(method_name, body).to_protobuf.to_slice

        response.write_byte 0
        response.write_bytes payload.bytesize, IO::ByteFormat::NetworkEndian
        response.write payload
        response.close
      end
    end

    def <<(handler : Protobuf::Service)
      @services[handler.class.service_name] = handler
      self
    end
  end
  
  class ThroughputLogger
    include HTTP2::Handler

    @reqs = Array(Time).new
    @running = false

    def call(context : HTTP2::Server::Context)
      ensure_running
      @reqs << Time.utc
      call_next context
    end

    private def ensure_running
      unless @running
        @running = true
        spawn do
          loop do
            latest = @reqs[-1]? || Time.utc
            sleep 1
            @reqs.select! { |t| t > latest }
            puts "Throughput: #{@reqs.size}/sec"
          end
        end
      end
    end
  end
end
