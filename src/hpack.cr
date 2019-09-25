# This implementation taken from https://github.com/ysbaddaden/http2/blob/a9c5f98b95f7f1fcfe88a6cc9fe99cf378df9ec6/src/hpack
# and updated for Crystal 0.31.0.
#
# Those files are distributed under the Apache License, version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# This version is distributed under the same MIT license as the rest of this project.

require "http/headers"

module HTTP2
  module HPACK
    @[Flags]
    enum Indexing : UInt8
      INDEXED = 128_u8
      ALWAYS = 64_u8
      NEVER = 16_u8
      NONE = 0_u8
    end

    class Error < Exception
    end

    struct Decoder
      private getter! reader : SliceReader
      getter table : DynamicTable
      property max_table_size : Int32

      def initialize(@max_table_size = 4096)
        @table = DynamicTable.new(@max_table_size)
      end

      def decode(bytes, headers = HTTP::Headers.new)
        @reader = SliceReader.new(bytes)
        decoded_common_headers = false

        until reader.done?
          if reader.current_byte.bit(7) == 1           # 1.......  indexed
            index = integer(7)
            raise Error.new("invalid index: 0") if index == 0
            name, value = indexed(index)

          elsif reader.current_byte.bit(6) == 1        # 01......  literal with incremental indexing
            index = integer(6)
            name = index == 0 ? string : indexed(index).first
            value = string
            table.add(name, value)

          elsif reader.current_byte.bit(5) == 1        # 001.....  table max size update
            raise Error.new("unexpected dynamic table size update") if decoded_common_headers
            if (new_size = integer(5)) > max_table_size
              raise Error.new("dynamic table size update is larger than SETTINGS_HEADER_TABLE_SIZE")
            end
            table.resize(new_size)
            next

          elsif reader.current_byte.bit(4) == 1        # 0001....  literal never indexed
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            value = string
            # TODO: retain the never_indexed property

          else                                         # 0000....  literal without indexing
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            value = string
          end

          decoded_common_headers = 0 < index < STATIC_TABLE_SIZE
          headers.add(name, value)
        end

        headers
      rescue ex : IndexError
        raise Error.new("invalid compression")
      end

      protected def indexed(index)
        if 0 < index < STATIC_TABLE_SIZE
          return STATIC_TABLE[index - 1]
        end

        if header = table[index - STATIC_TABLE_SIZE - 1]?
          return header
        end

        pp index: index, static_size: STATIC_TABLE_SIZE, dynamic_size: table.size

        raise Error.new("invalid index: #{index}")
      end

      protected def integer(n)
        integer = (reader.read_byte & (0xff >> (8 - n))).to_i
        n2 = 2 ** n - 1
        return integer if integer < n2

        m = 0
        loop do
          # TODO: raise if integer grows over limit
          byte = reader.read_byte
          integer += (byte & 127).to_i * (2 ** (m * 7))
          break unless byte & 128 == 128
          m += 1
        end

        integer
      end

      protected def string
        huffman = reader.current_byte.bit(7) == 1
        length = integer(7)
        bytes = reader.read(length)

        if huffman
          HPACK.huffman.decode(bytes)
        else
          String.new(bytes)
        end
      end
    end

    struct Encoder
      # TODO: allow per header name/value indexing configuration
      # TODO: allow per header name/value huffman encoding configuration

      private getter! writer : IO::Memory
      getter table : DynamicTable
      property default_indexing : Indexing
      property default_huffman : Bool

      def initialize(indexing = Indexing::NONE, huffman = false, max_table_size = 4096)
        @default_indexing = indexing
        @default_huffman = huffman
        @table = DynamicTable.new(max_table_size)
      end

      def encode(headers : HTTP::Headers, indexing = default_indexing, huffman = default_huffman, @writer = IO::Memory.new)
        headers.each { |name, values| encode(name.downcase, values, indexing, huffman) if name.starts_with?(':') }
        headers.each { |name, values| encode(name.downcase, values, indexing, huffman) unless name.starts_with?(':') }
        writer.to_slice
      end

      def encode(name, values, indexing, huffman)
        values.each do |value|
          if header = indexed(name, value)
            if header[1]
              integer(header[0], 7, prefix: Indexing::INDEXED)
            elsif indexing == Indexing::ALWAYS
              integer(header[0], 6, prefix: Indexing::ALWAYS)
              string(value, huffman)
              table.add(name, value)
            else
              integer(header[0], 4, prefix: Indexing::NONE)
              string(value, huffman)
            end
          else
            case indexing
            when Indexing::ALWAYS
              table.add(name, value)
              writer.write_byte(Indexing::ALWAYS.value)
            when Indexing::NEVER
              writer.write_byte(Indexing::NEVER.value)
            else
              writer.write_byte(Indexing::NONE.value)
            end
            string(name, huffman)
            string(value, huffman)
          end
        end
      end

      protected def indexed(name, value)
        # OPTIMIZE: use a cached { name => { value => index } } struct (?)
        idx = nil

        STATIC_TABLE.each_with_index do |header, index|
          if header[0] == name
            if header[1] == value
              return {index + 1, value}
            else
              idx ||= index + 1
            end
          end
        end

        table.each_with_index do |header, index|
          if header[0] == name
            if header[1] == value
              return {index + STATIC_TABLE_SIZE + 1, value}
            #else
            #  idx ||= index + 1
            end
          end
        end

        if idx
          {idx, nil}
        end
      end

      protected def integer(integer : Int32, n, prefix = 0_u8)
        n2 = 2 ** n - 1

        if integer < n2
          writer.write_byte(integer.to_u8 | prefix.to_u8)
          return
        end

        writer.write_byte(n2.to_u8 | prefix.to_u8)
        integer -= n2

        while integer >= 128
          writer.write_byte(((integer % 128) + 128).to_u8)
          integer /= 128
        end

        writer.write_byte(integer.to_u8)
      end

      protected def string(string : String, huffman = false)
        if huffman
          encoded = HPACK.huffman.encode(string)
          integer(encoded.size, 7, prefix: 128)
          writer.write(encoded)
        else
          integer(string.bytesize, 7)
          writer << string
        end
      end
    end
  end
end

module HTTP2
  module HPACK
    class Huffman
      class Node
        property left : Node? # bit 0
        property right : Node? # bit 1
        property value : UInt8?

        def leaf?
          left.nil? && right.nil?
        end

        def add(binary, len, value)
          node = self

          (len - 1).downto(0) do |i|
            if binary.bit(i) == 1
              node = (node.right ||= Node.new)
            else
              node = (node.left ||= Node.new)
            end
          end

          node.value = value
          node
        end
      end

      private getter tree : Node
      private getter table : Array({UInt8, Int32, Int32})

      def initialize(@table)
        @tree = Node.new

        table.each do |row|
          value, binary, len = row
          tree.add(binary, len, value)
        end
      end

      def encode(string : String)
        bytes = Bytes.new(string.bytesize)
        offset = k = 0

        string.each_byte do |chr|
          _, binary, len = table[chr]

          (len - 1).downto(0) do |i|
            j = offset % 8
            k = offset // 8 if j == 0
            bytes[k] |= 128 >> j if binary.bit(i) == 1
            offset += 1
          end
        end

        count = (offset / 8.0).ceil.to_i
        bytes[count - 1] |= 0xff >> (offset % 8) unless offset % 8 == 0 # padding
        bytes[0, count]
      end

      def decode(bytes : Bytes)
        io = IO::Memory.new
        node = tree
        eos_padding = true

        bytes.each do |byte|
          byte_has_value = false
          eos_padding = true

          7.downto(0) do |i|

            if byte.bit(i) == 1
              node = node.right
            else
              node = node.left
              eos_padding = false
            end

            raise Error.new("node is nil!") unless node

            if value = node.value
              io.write_byte(value)
              node = tree

              byte_has_value = true
              eos_padding = true
            end
          end

          # RFC 7541, section 5.2
          raise Error.new("huffman string padding is larger than 7-bits") unless byte_has_value
        end

        # RFC 7541, section 5.2
        raise Error.new("huffman string padding must use MSB of EOS symbol") unless eos_padding

        io.to_s
      end
    end

    def self.huffman
      @@huffman
    end

    @@huffman = Huffman.new [
      {0_u8,    0b1111111111000,                   13},
      {1_u8,    0b11111111111111111011000,         23},
      {2_u8,    0b1111111111111111111111100010,    28},
      {3_u8,    0b1111111111111111111111100011,    28},
      {4_u8,    0b1111111111111111111111100100,    28},
      {5_u8,    0b1111111111111111111111100101,    28},
      {6_u8,    0b1111111111111111111111100110,    28},
      {7_u8,    0b1111111111111111111111100111,    28},
      {8_u8,    0b1111111111111111111111101000,    28},
      {9_u8,    0b111111111111111111101010,        24},
      {10_u8,   0b111111111111111111111111111100,  30},
      {11_u8,   0b1111111111111111111111101001,    28},
      {12_u8,   0b1111111111111111111111101010,    28},
      {13_u8,   0b111111111111111111111111111101,  30},
      {14_u8,   0b1111111111111111111111101011,    28},
      {15_u8,   0b1111111111111111111111101100,    28},
      {16_u8,   0b1111111111111111111111101101,    28},
      {17_u8,   0b1111111111111111111111101110,    28},
      {18_u8,   0b1111111111111111111111101111,    28},
      {19_u8,   0b1111111111111111111111110000,    28},
      {20_u8,   0b1111111111111111111111110001,    28},
      {21_u8,   0b1111111111111111111111110010,    28},
      {22_u8,   0b111111111111111111111111111110,  30},
      {23_u8,   0b1111111111111111111111110011,    28},
      {24_u8,   0b1111111111111111111111110100,    28},
      {25_u8,   0b1111111111111111111111110101,    28},
      {26_u8,   0b1111111111111111111111110110,    28},
      {27_u8,   0b1111111111111111111111110111,    28},
      {28_u8,   0b1111111111111111111111111000,    28},
      {29_u8,   0b1111111111111111111111111001,    28},
      {30_u8,   0b1111111111111111111111111010,    28},
      {31_u8,   0b1111111111111111111111111011,    28},
      {32_u8,   0b010100,                          6},
      {33_u8,   0b1111111000,                      10},
      {34_u8,   0b1111111001,                      10},
      {35_u8,   0b111111111010,                    12},
      {36_u8,   0b1111111111001,                   13},
      {37_u8,   0b010101,                          6},
      {38_u8,   0b11111000,                        8},
      {39_u8,   0b11111111010,                     11},
      {40_u8,   0b1111111010,                      10},
      {41_u8,   0b1111111011,                      10},
      {42_u8,   0b11111001,                        8},
      {43_u8,   0b11111111011,                     11},
      {44_u8,   0b11111010,                        8},
      {45_u8,   0b010110,                          6},
      {46_u8,   0b010111,                          6},
      {47_u8,   0b011000,                          6},
      {48_u8,   0b00000,                           5},
      {49_u8,   0b00001,                           5},
      {50_u8,   0b00010,                           5},
      {51_u8,   0b011001,                          6},
      {52_u8,   0b011010,                          6},
      {53_u8,   0b011011,                          6},
      {54_u8,   0b011100,                          6},
      {55_u8,   0b011101,                          6},
      {56_u8,   0b011110,                          6},
      {57_u8,   0b011111,                          6},
      {58_u8,   0b1011100,                         7},
      {59_u8,   0b11111011,                        8},
      {60_u8,   0b111111111111100,                 15},
      {61_u8,   0b100000,                          6},
      {62_u8,   0b111111111011,                    12},
      {63_u8,   0b1111111100,                      10},
      {64_u8,   0b1111111111010,                   13},
      {65_u8,   0b100001,                          6},
      {66_u8,   0b1011101,                         7},
      {67_u8,   0b1011110,                         7},
      {68_u8,   0b1011111,                         7},
      {69_u8,   0b1100000,                         7},
      {70_u8,   0b1100001,                         7},
      {71_u8,   0b1100010,                         7},
      {72_u8,   0b1100011,                         7},
      {73_u8,   0b1100100,                         7},
      {74_u8,   0b1100101,                         7},
      {75_u8,   0b1100110,                         7},
      {76_u8,   0b1100111,                         7},
      {77_u8,   0b1101000,                         7},
      {78_u8,   0b1101001,                         7},
      {79_u8,   0b1101010,                         7},
      {80_u8,   0b1101011,                         7},
      {81_u8,   0b1101100,                         7},
      {82_u8,   0b1101101,                         7},
      {83_u8,   0b1101110,                         7},
      {84_u8,   0b1101111,                         7},
      {85_u8,   0b1110000,                         7},
      {86_u8,   0b1110001,                         7},
      {87_u8,   0b1110010,                         7},
      {88_u8,   0b11111100,                        8},
      {89_u8,   0b1110011,                         7},
      {90_u8,   0b11111101,                        8},
      {91_u8,   0b1111111111011,                   13},
      {92_u8,   0b1111111111111110000,             19},
      {93_u8,   0b1111111111100,                   13},
      {94_u8,   0b11111111111100,                  14},
      {95_u8,   0b100010,                          6},
      {96_u8,   0b111111111111101,                 15},
      {97_u8,   0b00011,                           5},
      {98_u8,   0b100011,                          6},
      {99_u8,   0b00100,                           5},
      {100_u8,  0b100100,                          6},
      {101_u8,  0b00101,                           5},
      {102_u8,  0b100101,                          6},
      {103_u8,  0b100110,                          6},
      {104_u8,  0b100111,                          6},
      {105_u8,  0b00110,                           5},
      {106_u8,  0b1110100,                         7},
      {107_u8,  0b1110101,                         7},
      {108_u8,  0b101000,                          6},
      {109_u8,  0b101001,                          6},
      {110_u8,  0b101010,                          6},
      {111_u8,  0b00111,                           5},
      {112_u8,  0b101011,                          6},
      {113_u8,  0b1110110,                         7},
      {114_u8,  0b101100,                          6},
      {115_u8,  0b01000,                           5},
      {116_u8,  0b01001,                           5},
      {117_u8,  0b101101,                          6},
      {118_u8,  0b1110111,                         7},
      {119_u8,  0b1111000,                         7},
      {120_u8,  0b1111001,                         7},
      {121_u8,  0b1111010,                         7},
      {122_u8,  0b1111011,                         7},
      {123_u8,  0b111111111111110,                 15},
      {124_u8,  0b11111111100,                     11},
      {125_u8,  0b11111111111101,                  14},
      {126_u8,  0b1111111111101,                   13},
      {127_u8,  0b1111111111111111111111111100,    28},
      {128_u8,  0b11111111111111100110,            20},
      {129_u8,  0b1111111111111111010010,          22},
      {130_u8,  0b11111111111111100111,            20},
      {131_u8,  0b11111111111111101000,            20},
      {132_u8,  0b1111111111111111010011,          22},
      {133_u8,  0b1111111111111111010100,          22},
      {134_u8,  0b1111111111111111010101,          22},
      {135_u8,  0b11111111111111111011001,         23},
      {136_u8,  0b1111111111111111010110,          22},
      {137_u8,  0b11111111111111111011010,         23},
      {138_u8,  0b11111111111111111011011,         23},
      {139_u8,  0b11111111111111111011100,         23},
      {140_u8,  0b11111111111111111011101,         23},
      {141_u8,  0b11111111111111111011110,         23},
      {142_u8,  0b111111111111111111101011,        24},
      {143_u8,  0b11111111111111111011111,         23},
      {144_u8,  0b111111111111111111101100,        24},
      {145_u8,  0b111111111111111111101101,        24},
      {146_u8,  0b1111111111111111010111,          22},
      {147_u8,  0b11111111111111111100000,         23},
      {148_u8,  0b111111111111111111101110,        24},
      {149_u8,  0b11111111111111111100001,         23},
      {150_u8,  0b11111111111111111100010,         23},
      {151_u8,  0b11111111111111111100011,         23},
      {152_u8,  0b11111111111111111100100,         23},
      {153_u8,  0b111111111111111011100,           21},
      {154_u8,  0b1111111111111111011000,          22},
      {155_u8,  0b11111111111111111100101,         23},
      {156_u8,  0b1111111111111111011001,          22},
      {157_u8,  0b11111111111111111100110,         23},
      {158_u8,  0b11111111111111111100111,         23},
      {159_u8,  0b111111111111111111101111,        24},
      {160_u8,  0b1111111111111111011010,          22},
      {161_u8,  0b111111111111111011101,           21},
      {162_u8,  0b11111111111111101001,            20},
      {163_u8,  0b1111111111111111011011,          22},
      {164_u8,  0b1111111111111111011100,          22},
      {165_u8,  0b11111111111111111101000,         23},
      {166_u8,  0b11111111111111111101001,         23},
      {167_u8,  0b111111111111111011110,           21},
      {168_u8,  0b11111111111111111101010,         23},
      {169_u8,  0b1111111111111111011101,          22},
      {170_u8,  0b1111111111111111011110,          22},
      {171_u8,  0b111111111111111111110000,        24},
      {172_u8,  0b111111111111111011111,           21},
      {173_u8,  0b1111111111111111011111,          22},
      {174_u8,  0b11111111111111111101011,         23},
      {175_u8,  0b11111111111111111101100,         23},
      {176_u8,  0b111111111111111100000,           21},
      {177_u8,  0b111111111111111100001,           21},
      {178_u8,  0b1111111111111111100000,          22},
      {179_u8,  0b111111111111111100010,           21},
      {180_u8,  0b11111111111111111101101,         23},
      {181_u8,  0b1111111111111111100001,          22},
      {182_u8,  0b11111111111111111101110,         23},
      {183_u8,  0b11111111111111111101111,         23},
      {184_u8,  0b11111111111111101010,            20},
      {185_u8,  0b1111111111111111100010,          22},
      {186_u8,  0b1111111111111111100011,          22},
      {187_u8,  0b1111111111111111100100,          22},
      {188_u8,  0b11111111111111111110000,         23},
      {189_u8,  0b1111111111111111100101,          22},
      {190_u8,  0b1111111111111111100110,          22},
      {191_u8,  0b11111111111111111110001,         23},
      {192_u8,  0b11111111111111111111100000,      26},
      {193_u8,  0b11111111111111111111100001,      26},
      {194_u8,  0b11111111111111101011,            20},
      {195_u8,  0b1111111111111110001,             19},
      {196_u8,  0b1111111111111111100111,          22},
      {197_u8,  0b11111111111111111110010,         23},
      {198_u8,  0b1111111111111111101000,          22},
      {199_u8,  0b1111111111111111111101100,       25},
      {200_u8,  0b11111111111111111111100010,      26},
      {201_u8,  0b11111111111111111111100011,      26},
      {202_u8,  0b11111111111111111111100100,      26},
      {203_u8,  0b111111111111111111111011110,     27},
      {204_u8,  0b111111111111111111111011111,     27},
      {205_u8,  0b11111111111111111111100101,      26},
      {206_u8,  0b111111111111111111110001,        24},
      {207_u8,  0b1111111111111111111101101,       25},
      {208_u8,  0b1111111111111110010,             19},
      {209_u8,  0b111111111111111100011,           21},
      {210_u8,  0b11111111111111111111100110,      26},
      {211_u8,  0b111111111111111111111100000,     27},
      {212_u8,  0b111111111111111111111100001,     27},
      {213_u8,  0b11111111111111111111100111,      26},
      {214_u8,  0b111111111111111111111100010,     27},
      {215_u8,  0b111111111111111111110010,        24},
      {216_u8,  0b111111111111111100100,           21},
      {217_u8,  0b111111111111111100101,           21},
      {218_u8,  0b11111111111111111111101000,      26},
      {219_u8,  0b11111111111111111111101001,      26},
      {220_u8,  0b1111111111111111111111111101,    28},
      {221_u8,  0b111111111111111111111100011,     27},
      {222_u8,  0b111111111111111111111100100,     27},
      {223_u8,  0b111111111111111111111100101,     27},
      {224_u8,  0b11111111111111101100,            20},
      {225_u8,  0b111111111111111111110011,        24},
      {226_u8,  0b11111111111111101101,            20},
      {227_u8,  0b111111111111111100110,           21},
      {228_u8,  0b1111111111111111101001,          22},
      {229_u8,  0b111111111111111100111,           21},
      {230_u8,  0b111111111111111101000,           21},
      {231_u8,  0b11111111111111111110011,         23},
      {232_u8,  0b1111111111111111101010,          22},
      {233_u8,  0b1111111111111111101011,          22},
      {234_u8,  0b1111111111111111111101110,       25},
      {235_u8,  0b1111111111111111111101111,       25},
      {236_u8,  0b111111111111111111110100,        24},
      {237_u8,  0b111111111111111111110101,        24},
      {238_u8,  0b11111111111111111111101010,      26},
      {239_u8,  0b11111111111111111110100,         23},
      {240_u8,  0b11111111111111111111101011,      26},
      {241_u8,  0b111111111111111111111100110,     27},
      {242_u8,  0b11111111111111111111101100,      26},
      {243_u8,  0b11111111111111111111101101,      26},
      {244_u8,  0b111111111111111111111100111,     27},
      {245_u8,  0b111111111111111111111101000,     27},
      {246_u8,  0b111111111111111111111101001,     27},
      {247_u8,  0b111111111111111111111101010,     27},
      {248_u8,  0b111111111111111111111101011,     27},
      {249_u8,  0b1111111111111111111111111110,    28},
      {250_u8,  0b111111111111111111111101100,     27},
      {251_u8,  0b111111111111111111111101101,     27},
      {252_u8,  0b111111111111111111111101110,     27},
      {253_u8,  0b111111111111111111111101111,     27},
      {254_u8,  0b111111111111111111111110000,     27},
      {255_u8,  0b11111111111111111111101110,      26},
     #{256_u8,  0b111111111111111111111111111111,  30}, # EOS symbol (invalid)
    ]
  end
end

module HTTP2
  module HPACK

    # :nodoc:
    STATIC_TABLE = {
      {":authority", ""},
      {":method", "GET"},
      {":method", "POST"},
      {":path", "/"},
      {":path", "/index.html"},
      {":scheme", "http"},
      {":scheme", "https"},
      {":status", "200"},
      {":status", "204"},
      {":status", "206"},
      {":status", "304"},
      {":status", "400"},
      {":status", "404"},
      {":status", "500"},
      {"accept-charset", ""},
      {"accept-encoding", "gzip, deflate"},
      {"accept-language", ""},
      {"accept-ranges", ""},
      {"accept", ""},
      {"access-control-allow-origin", ""},
      {"age", ""},
      {"allow", ""},
      {"authorization", ""},
      {"cache-control", ""},
      {"content-disposition", ""},
      {"content-encoding", ""},
      {"content-language", ""},
      {"content-length", ""},
      {"content-location", ""},
      {"content-range", ""},
      {"content-type", ""},
      {"cookie", ""},
      {"date", ""},
      {"etag", ""},
      {"expect", ""},
      {"expires", ""},
      {"from", ""},
      {"host", ""},
      {"if-match", ""},
      {"if-modified-since", ""},
      {"if-none-match", ""},
      {"if-range", ""},
      {"if-unmodified-since", ""},
      {"last-modified", ""},
      {"link", ""},
      {"location", ""},
      {"max-forwards", ""},
      {"proxy-authenticate", ""},
      {"proxy-authorization", ""},
      {"range", ""},
      {"referer", ""},
      {"refresh", ""},
      {"retry-after", ""},
      {"server", ""},
      {"set-cookie", ""},
      {"strict-transport-security", ""},
      {"transfer-encoding", ""},
      {"user-agent", ""},
      {"vary", ""},
      {"via", ""},
      {"www-authenticate", ""},
    }

    # :nodoc:
    STATIC_TABLE_SIZE = STATIC_TABLE.size

  end
end

module HTTP2
  module HPACK
    class DynamicTable
      getter bytesize : Int32
      getter maximum : Int32

      def initialize(@maximum)
        @bytesize = 0
        @table = [] of Tuple(String, String)
      end

      def add(name, value)
        header = {name, value}
        @table.unshift(header)
        @bytesize += count(header)
        cleanup
        nil
      end

      def [](index)
        @table[index]
      end

      def []?(index)
        @table[index]?
      end

      def each
        @table.each { |header, index| yield header, index }
      end

      def each_with_index
        @table.each_with_index { |header, index| yield header, index }
      end

      def size
        @table.size
      end

      def empty?
        @table.empty?
      end

      def resize(@maximum)
        cleanup
        nil
      end

      private def cleanup
        while bytesize > maximum
          @bytesize -= count(@table.pop)
        end
      end

      private def count(header)
        header[0].bytesize + header[1].bytesize + 32
      end
    end
  end
end

module HTTP2
  class SliceReader
    getter offset : Int32
    getter bytes : Bytes
    getter default_endianness : IO::ByteFormat

    def initialize(@bytes : Bytes, @default_endianness = IO::ByteFormat::SystemEndian)
      @offset = 0
    end

    def done?
      offset >= bytes.size
    end

    def current_byte
      bytes[offset]
    end

    def read_byte
      current_byte.tap { @offset += 1 }
    end

    {% for type, i in %w(UInt8 Int8 UInt16 Int16 UInt32 Int32 UInt64 Int64) %}
      def read_bytes(type : {{ type.id }}.class, endianness = default_endianness)
        {% size = 2 ** (i / 2) %}

        buffer = bytes[offset, {{ size }}]
        @offset += {{ size }}

        {% if size > 1 %}
          unless endianness == IO::ByteFormat::SystemEndian
            buffer.reverse!
          end
        {% end %}

        buffer.to_unsafe.as(Pointer({{ type.id }})).value
      end
    {% end %}

    def read(count)
      count = bytes.size - offset - count if count < 0
      bytes[offset, count].tap { @offset += count }
    end
  end
end
