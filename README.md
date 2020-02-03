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

## Usage

1. Write a `protos/#{name}.proto` file that contains a `service` entry:

  ```protobuf
  syntax "proto3";

  service MyService {
    rpc MyMethod (MyRequest) returns (MyResponse) {}
  }
  ```

2. Compile the `.proto` file
  1. Write a Crystal program that simply has

```crystal
require "grpc"
```

First we'll set up a `GRPC::Server` and pass:

```crystal
```

The gRPC protocol runs on top of HTTP/2, so this library contains a partial implementation of HTTP/2. You'll need to set up an HTTP/2 server that will manage the connections:

```crystal
http2 = HTTP2::Server.new
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
