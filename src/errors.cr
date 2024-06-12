module GRPC
  class BadStatus < Exception
    getter code : StatusCode

    def initialize(@code : StatusCode, @message : String = "")
    end
  end
end
