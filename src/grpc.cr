require "uuid"
require "mutex"
require "protobuf"

require "./http2"
require "./service"

module GRPC
  class Server
    include HTTP2::Handler

    @services = Hash(String, Service).new

    def call(context : HTTP2::Server::Context)
      request, response = context.request, context.response

      if body = request.body
        compressed = body.read_bytes(UInt8) != 0
        length = body.read_bytes(UInt32, IO::ByteFormat::NetworkEndian)

        _, service_name, method_name = request.headers[":path"].split('/')
        service = @services[service_name]
        context.response.headers["content-type"] = "application/grpc+proto"
        payload = service.handle(method_name, body).to_protobuf.to_slice

        response.write_byte 0
        response.write_bytes payload.bytesize, IO::ByteFormat::NetworkEndian
        response.write payload
        response.close
      end
    end

    def <<(handler : Service)
      @services[handler.class.service_name] = handler
      self
    end
  end
end
