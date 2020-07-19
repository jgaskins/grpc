require "./http2"

module GRPC
  module Service
    class Error < Exception
    end

    class InvalidMethodName < Error
    end

    macro included
      def self.service_name
        @@service_name
      end

      def handle(method_name : String, request_body : IO)
        raise InvalidMethodName.new("Unknown RPC method {{@type.id}}/#{method_name}")
      end

      macro rpc(name, receives request_type, returns response_type)
        \{% method_name = name.stringify.underscore.id %}
        abstract def \{{method_name}}(request : \{{request_type}}) : \{{response_type}}

        def handle(method_name : String, request_body : IO)
          if method_name == \{{name.stringify}}
            \{{method_name}}(\{{request_type}}.from_protobuf(request_body))
          else
            previous_def(method_name, request_body)
          end
        end

        class Stub < ::GRPC::Service::Stub({{@type.id}})
          def \{{method_name}}(request : \{{request_type}}) : \{{response_type}}
            io = IO::Memory.new

            request_payload = request.to_protobuf.to_slice

            io.write_bytes(0_u8) # Not compressed
            io.write_bytes(request_payload.size, IO::ByteFormat::NetworkEndian)
            io.write request_payload

            response = @client.send(
              headers: HTTP::Headers {
                ":method" => "POST",
                ":path" => "/#{T.service_name}/\{{name}}",
                "content-type" => "application/grpc-web+proto",
              },
              body: io.to_slice,
            )

            compressed = response.read_byte != 0 # TODO: Handle compression?
            length = response.read_bytes Int32, IO::ByteFormat::NetworkEndian

            \{{response_type}}.from_protobuf(response)
          end
        end
      end
    end

    class Stub(T)
      def initialize(host : String, port : Int32)
        @client = HTTP2::Client.new(host, port)
      end
    end
  end
end
