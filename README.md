# GRPC

This project is a pure-Crystal implementation of gRPC.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     grpc:
       github: jgaskins/grpc
   ```

2. Run `shards install`

3. Make sure you have Google's `grpc` tools installed

   - macOS: `brew install grpc`

## Usage

1. Write a `protos/hello_world.proto` file that contains a `service` entry and any message types it depends on:

   ```protobuf
   syntax = "proto3";

   service HelloWorld {
     rpc MethodName (TheRequest) returns (TheResponse) {}
   }

   message TheRequest {
     string text = 1;
   }

   message TheResponse {
     string data = 1;
   }
   ```

2. Compile the `.proto` files. If your messages are defined in `protos/hello_world.proto` and you want your code written out to the app's `src/protobufs` directory, use the following command:
   
   ```
   $ protoc -I protos \
       --grpc_out=src/protobufs \
       --crystal_out=src/protobufs \
       --plugin=protoc-gen-grpc=bin/grpc_crystal \
       --plugin=protoc-gen-crystal=bin/protoc-gen-crystal \
       protos/hello_world.proto
   ```

   This compiles both the service and the messages.

## Server

To handle gRPC requests for the above service definition, we need 3 things:

- One or more service handlers
- A gRPC server
- An HTTP/2 server to wrap the gRPC server (gRPC runs on top of HTTP/2)

### Service Handlers

Services are compiled into abstract classes with the `protoc` command above. To implement a handler for a given service, we subclass the generated abstract class, defining the methods with snake_cased names:

```crystal
require "./protobufs/hello_world_services.pb"
require "./protobufs/hello_world.pb"

class HelloWorldHandler < HelloWorld
  # You can define your own initialize method to inject dependencies

  def method_name(request : TheRequest) : TheResponse
    TheResponse.new(data: "Hello #{request.text}")
  end
end
```

The methods defined in the service declaration are required to be implemented by this class. Your program will not compile without them.

### gRPC Server

```crystal
require "grpc"
grpc = GRPC::Server.new
grpc << HelloWorldHandler.new
```

You can add as many service handlers as you like.

### HTTP/2 Server

The `HTTP2::Server` works similarly to `HTTP::Server`:

```crystal
require "grpc/http2"
server = HTTP2::ClearTextServer.new([grpc]) # TLS isn't supported yet
server.listen "0.0.0.0", 50000
```

And now gRPC requests for your `HelloWorld` service will be handled by `HelloWorldHandler`.

## Client

To write a client to consume the `HelloWorld` service, you simply use a `Stub`:

```crystal
# Load the service and message definitions
require "./protobufs/hello_world_services.pb"
require "./protobufs/hello_world.pb"

HelloWorldService = HelloWorld::Stub.new("localhost", 50000)

# from anywhere in your app
pp HelloWorldService.method_name(TheRequest.new(text: "foo"))
# => TheResponse(@data="Hello foo")
```

## Limitations

This implementation currently only supports "simple gRPC" — send a synchronous request, get a synchronous response. Streaming is not yet implemented.

## Roadmap

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/jgaskins/grpc/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
