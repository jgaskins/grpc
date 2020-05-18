require "protobuf"
require "logger"

module GRPC
  class Generator
    class_getter logger
    @@logger = Logger.new(STDERR, level: Logger::INFO)

    class Error < Exception
    end

    def self.call
      compile(Protobuf::CodeGeneratorRequest.from_protobuf(STDIN))
        .to_protobuf(STDOUT)
    end

    def self.compile(request)
      if proto_files = request.proto_file
        package_map = PackageMap.new

        proto_files.each do |file|
          logger.debug "Processing #{file}..."
          if !file.package.nil?
            package_map[file.package.not_nil!] = file.crystal_ns.join("::")
          end
        end

        files = proto_files.map do |file|
          Protobuf::CodeGeneratorResponse::File.new(
            name: "#{File.basename(file.name.not_nil!, ".proto")}_services.pb.cr",
            content: new(file, package_map).compile,
          )
        end
        Protobuf::CodeGeneratorResponse.new(file: files)
      else
        raise Error.new("no files to generate")
      end
    end

    alias PackageMap = Hash(String, String)

    getter buffer = String::Builder.new
    @indentation = 0
    @ns : Array(String)

    delegate package, to: @file

    def initialize(
      @file : Protobuf::CodeGeneratorRequest::FileDescriptorProto,
      @package_map : PackageMap,
    )
      @ns = ENV
        .fetch("PROTOBUF_NS", "")
        .split("::")
        .reject(&.empty?)
        .concat(file.crystal_ns)
    end

    def compile
      package_part = package ? "for #{package}" : ""
      puts "## Generated from #{@file.name} #{package_part}".strip
      puts "require \"grpc/service\""

      puts

      if (dependency = @file.dependency)
        dependency.each do |dp|
          puts "require \"./#{File.basename(dp.not_nil!, ".proto") + ".pb.cr"}\""
        end
        puts
      end

      if package_name = package
        package_namespace = "#{package_name.split('.').map(&.camelcase).join("::")}::"
      end

      namespace do
        if service = @file.service
          service.each do |service|
            puts "abstract class #{package_namespace}#{service.name}"
            indent do
              puts "include GRPC::Service"
              puts
              puts %{@@service_name = "#{package_name}.#{service.name}"}
              puts
              if method = service.method
                method.each do |m|
                  input_type = m.input_type.not_nil!.split('.').map(&.camelcase).join("::")
                  output_type = m.output_type.not_nil!.split('.').map(&.camelcase).join("::")
                  puts "rpc #{m.name}, receives: #{input_type}, returns: #{output_type}"
                end
              end
            end
            puts "end"
          end
        end
      end

      buffer.to_s
    end

    def namespace
      return yield if @ns.empty?
      @ns.each do |ns|
        puts "module #{ns}"
        @indentation += 1
      end
      yield
      @ns.each do |ns|
        @indentation -= 1
        puts "end"
      end
    end

    def indent
      @indentation += 1
      yield
      @indentation -= 1
    end

    def puts(*strings : String)
      strings.each do |string|
        buffer.puts "#{"  " * @indentation}#{string}"
      end
    end

    def puts
      buffer.puts
    end
  end
end
