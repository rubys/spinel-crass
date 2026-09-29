# encoding: utf-8
require_relative 'scanner'

module Crass

  # Tokenizes a CSS string.
  #
  # 4. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#tokenization
  class Tokenizer
    RE_COMMENT_CLOSE   = /\*\//
    RE_DIGIT           = /[0-9]+/
    RE_ESCAPE          = /\\[^\n]/
    RE_HEX             = /[0-9A-Fa-f]{1,6}/
    RE_NAME            = /[0-9A-Za-z_\u0080-\u{10ffff}-]+/
    RE_NAME_START      = /[A-Za-z_\u0080-\u{10ffff}]+/
    RE_NON_PRINTABLE   = /[\u0000-\u0008\u000b\u000e-\u001f\u007f]+/
    RE_NUMBER_DECIMAL  = /\.[0-9]+/
    RE_NUMBER_EXPONENT = /[Ee][+-]?[0-9]+/
    RE_NUMBER_SIGN     = /[+-]/

    # spinel-crass: at or past this a Float cannot be a 64-bit Integer (2**63
    # is 9.223e18); see convert_string_to_number.
    INT64_FLOAT_LIMIT = 9.2e18

    RE_NUMBER_STR = /\A
      (?<sign> [+-]?)
      (?<integer> [0-9]*)
      (?:\.
        (?<fractional> [0-9]*)
      )?
      (?:[Ee]
        (?<exponent_sign> [+-]?)
        (?<exponent> [0-9]*)
      )?
    \z/x

    RE_QUOTED_URL_START    = /\A[\n\u0009\u0020]?["']/
    RE_UNICODE_RANGE_START = /\+(?:[0-9A-Fa-f]|\?)/
    RE_UNICODE_RANGE_END   = /-[0-9A-Fa-f]/
    RE_WHITESPACE          = /[\n\u0009\u0020]+/
    RE_WHITESPACE_ANCHORED = /\A[\n\u0009\u0020]+\z/

    # -- Class Methods ---------------------------------------------------------

    # Tokenizes the given _input_ as a CSS string and returns an array of
    # tokens.
    #
    # See {#initialize} for _options_.
    def self.tokenize(input, options = {})
      Tokenizer.new(input, options).tokenize
    end

    # -- Instance Methods ------------------------------------------------------

    # Initializes a new Tokenizer.
    #
    # Options:
    #
    #   * **:preserve_comments** - If `true`, comments will be preserved as
    #     `:comment` tokens.
    #
    #   * **:preserve_hacks** - If `true`, certain non-standard browser hacks
    #     such as the IE "*" hack will be preserved even though they violate
    #     CSS 3 syntax rules.
    #
    def initialize(input, options = {})
      @s       = Scanner.new(preprocess(input))
      @options = options
    end

    # Consumes a token and returns the token that was consumed.
    #
    # 4.3.1. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-a-token
    def consume
      # Skip over any comments. When comments aren't being preserved this is
      # done iteratively rather than recursively so that a long run of adjacent
      # comments can't exhaust the Ruby stack and raise a `SystemStackError`.
      loop do
        return nil if @s.eos?

        @s.mark

        comment_token = consume_comments
        break unless comment_token

        return comment_token if @options[:preserve_comments]
      end

      # Consume whitespace.
      return create_token(:whitespace) if @s.scan(RE_WHITESPACE)

      char = @s.consume

      case char.to_sym
      when :'"'
        consume_string

      when :'#'
        if @s.peek =~ RE_NAME || valid_escape?(@s.peek(2))
          create_token(:hash,
            :type  => start_identifier?(@s.peek(3)) ? :id : :unrestricted,
            :value => consume_name)
        else
          create_token(:delim, :value => char)
        end

      when :'$'
        if @s.peek == '='
          @s.consume
          create_token(:suffix_match)
        else
          create_token(:delim, :value => char)
        end

      when :"'"
        consume_string

      when :'('
        create_token(:'(')

      when :')'
        create_token(:')')

      when :*
        if @s.peek == '='
          @s.consume
          create_token(:substring_match)

        # Non-standard: Preserve the IE * hack.
        elsif @options[:preserve_hacks] && @s.peek =~ RE_NAME_START
          @s.reconsume
          consume_ident

        else
          create_token(:delim, :value => char)
        end

      when :+
        if start_number?
          @s.reconsume
          consume_numeric
        else
          create_token(:delim, :value => char)
        end

      when :','
        create_token(:comma)

      when :-
        nextTwoChars   = @s.peek(2)
        nextThreeChars = char + nextTwoChars

        if start_number?(nextThreeChars)
          @s.reconsume
          consume_numeric
        elsif nextTwoChars == '->'
          @s.consume
          @s.consume
          create_token(:cdc)
        elsif start_identifier?(nextThreeChars)
          @s.reconsume
          consume_ident
        else
          create_token(:delim, :value => char)
        end

      when :'.'
        if start_number?
          @s.reconsume
          consume_numeric
        else
          create_token(:delim, :value => char)
        end

      when :':'
        create_token(:colon)

      when :';'
        create_token(:semicolon)

      when :<
        if @s.peek(3) == '!--'
          @s.consume
          @s.consume
          @s.consume

          create_token(:cdo)
        else
          create_token(:delim, :value => char)
        end

      when :'@'
        if start_identifier?(@s.peek(3))
          create_token(:at_keyword, :value => consume_name)
        else
          create_token(:delim, :value => char)
        end

      when :'['
        create_token(:'[')

      when :'\\'
        if valid_escape?
          @s.reconsume
          consume_ident
        else
          # Parse error.
          create_token(:delim,
            :error => true,
            :value => char)
        end

      when :']'
        create_token(:']')

      when :'^'
        if @s.peek == '='
          @s.consume
          create_token(:prefix_match)
        else
          create_token(:delim, :value => char)
        end

      when :'{'
        create_token(:'{')

      when :'}'
        create_token(:'}')

      when :U, :u
        if @s.peek(2) =~ RE_UNICODE_RANGE_START
          @s.consume
          consume_unicode_range
        else
          @s.reconsume
          consume_ident
        end

      when :|
        case @s.peek
        when '='
          @s.consume
          create_token(:dash_match)

        when '|'
          @s.consume
          create_token(:column)

        else
          create_token(:delim, :value => char)
        end

      when :~
        if @s.peek == '='
          @s.consume
          create_token(:include_match)
        else
          create_token(:delim, :value => char)
        end

      else
        case char
        when RE_DIGIT
          @s.reconsume
          consume_numeric

        when RE_NAME_START
          @s.reconsume
          consume_ident

        else
          create_token(:delim, :value => char)
        end
      end
    end

    # Consumes the remnants of a bad URL and returns the consumed text.
    #
    # 4.3.15. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-the-remnants-of-a-bad-url
    def consume_bad_url
      text = String.new

      until @s.eos?
        if valid_escape?
          text << consume_escaped
        elsif valid_escape?(@s.peek(2))
          @s.consume
          text << consume_escaped
        else
          char = @s.consume

          if char == ')'
            break
          else
            text << char
          end
        end
      end

      text
    end

    # Consumes comments and returns them, or `nil` if no comments were consumed.
    #
    # 4.3.2. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-comments
    def consume_comments
      if @s.peek(2) == '/*'
        @s.consume
        @s.consume

        if text = @s.scan_until(RE_COMMENT_CLOSE)
          text.slice!(-2, 2)
        else
          # Parse error.
          text = @s.consume_rest
        end

        return create_token(:comment, :value => text)
      end

      nil
    end

    # Consumes an escaped code point and returns its unescaped value.
    #
    # This method assumes that the `\` has already been consumed, and that the
    # next character in the input has already been verified not to be a newline
    # or EOF.
    #
    # 4.3.8. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-an-escaped-code-point
    def consume_escaped
      return "\ufffd" if @s.eos?

      if hex_str = @s.scan(RE_HEX)
        @s.consume if @s.peek =~ RE_WHITESPACE

        codepoint = hex_str.hex

        if codepoint == 0 ||
            codepoint.between?(0xD800, 0xDFFF) ||
            codepoint > 0x10FFFF

          return "\ufffd"
        else
          return codepoint.chr(Encoding::UTF_8)
        end
      end

      @s.consume
    end

    # Consumes an ident-like token and returns it.
    #
    # 4.3.4. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-an-ident-like-token
    def consume_ident
      value = consume_name

      if @s.peek == '('
        @s.consume

        if value.downcase == 'url'
          @s.consume while @s.peek(2) =~ RE_WHITESPACE_ANCHORED

          if @s.peek(2) =~ RE_QUOTED_URL_START
            create_token(:function, :value => value)
          else
            consume_url
          end
        else
          create_token(:function, :value => value)
        end
      else
        create_token(:ident, :value => value)
      end
    end

    # Consumes a name and returns it.
    #
    # 4.3.12. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-a-name
    def consume_name
      result = String.new

      until @s.eos?
        if match = @s.scan(RE_NAME)
          result << match
          next
        end

        char = @s.consume

        if valid_escape?
          result << consume_escaped

        # Non-standard: IE * hack
        elsif char == '*' && @options[:preserve_hacks]
          result << @s.consume

        else
          @s.reconsume
          return result
        end
      end

      result
    end

    # Consumes a number and returns a 3-element array containing the number's
    # original representation, its numeric value, and its type (either
    # `:integer` or `:number`).
    #
    # 4.3.13. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-a-number
    def consume_number
      repr = String.new
      type = :integer

      repr << @s.consume if @s.peek =~ RE_NUMBER_SIGN
      repr << (@s.scan(RE_DIGIT) || '')

      if match = @s.scan(RE_NUMBER_DECIMAL)
        repr << match
        type = :number
      end

      if match = @s.scan(RE_NUMBER_EXPONENT)
        repr << match
        type = :number
      end

      [repr, convert_string_to_number(repr), type]
    end

    # Consumes a numeric token and returns it.
    #
    # 4.3.3. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-a-numeric-token
    def consume_numeric
      number = consume_number
      repr = number[0]
      value = number[1]
      type = number[2]

      if type == :integer
        # spinel-crass: an integer too long for 64 bits keeps the Float that
        # convert_string_to_number answered for it, where CRuby's to_i would
        # be a Bignum (see there).
        value = value.to_i unless value.is_a?(Float) && value.abs >= INT64_FLOAT_LIMIT
      else
        value = value.to_f
      end

      if start_identifier?(@s.peek(3))
        create_token(:dimension,
          :repr => repr,
          :type => type,
          :unit => consume_name,
          :value => value)

      elsif @s.peek == '%'
        @s.consume

        create_token(:percentage,
          :repr => repr,
          :type => type,
          :value => value)

      else
        create_token(:number,
          :repr => repr,
          :type => type,
          :value => value)
      end
    end

    # Consumes a string token that ends at the given character, and returns the
    # token.
    #
    # 4.3.5. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-a-string-token
    def consume_string(ending = nil)
      ending = @s.current if ending.nil?
      value  = String.new

      until @s.eos?
        case char = @s.consume
        when ending
          break

        when "\n"
          # Parse error.
          @s.reconsume
          return create_token(:bad_string,
            :error => true,
            :value => value)

        when '\\'
          case @s.peek
          when ''
            # End of the input, so do nothing.
            next

          when "\n"
            @s.consume

          else
            value << consume_escaped
          end

        else
          value << char
        end
      end

      create_token(:string, :value => value)
    end

    # Consumes a Unicode range token and returns it. Assumes the initial "u+" or
    # "U+" has already been consumed.
    #
    # 4.3.7. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-a-unicode-range-token
    def consume_unicode_range
      value = @s.scan(RE_HEX) || String.new

      while value.length < 6
        break unless @s.peek == '?'
        value << @s.consume
      end

      range = {}

      if value.include?('?')
        range[:start] = value.gsub('?', '0').hex
        range[:end]   = value.gsub('?', 'F').hex
        return create_token(:unicode_range, range)
      end

      range[:start] = value.hex

      if @s.peek(2) =~ RE_UNICODE_RANGE_END
        @s.consume
        range[:end] = (@s.scan(RE_HEX) || '').hex
      else
        range[:end] = range[:start]
      end

      create_token(:unicode_range, range)
    end

    # Consumes a URL token and returns it. Assumes the original "url(" has
    # already been consumed.
    #
    # 4.3.6. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#consume-a-url-token
    def consume_url
      value = String.new

      @s.scan(RE_WHITESPACE)

      until @s.eos?
        case char = @s.consume
        when ')'
          break

        when RE_WHITESPACE
          @s.scan(RE_WHITESPACE)

          if @s.eos? || @s.peek == ')'
            @s.consume
            break
          else
            return create_token(:bad_url, :value => value + consume_bad_url)
          end

        when '"', "'", '(', RE_NON_PRINTABLE
          # Parse error.
          return create_token(:bad_url,
            :error => true,
            :value => value + consume_bad_url)

        when '\\'
          if valid_escape?
            value << consume_escaped
          else
            # Parse error.
            return create_token(:bad_url,
              :error => true,
              :value => value + consume_bad_url
            )
          end

        else
          value << char
        end
      end

      create_token(:url, :value => value)
    end

    # Converts a valid CSS number string into a number and returns the number.
    #
    # 4.3.14. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#convert-a-string-to-a-number
    def convert_string_to_number(str)
      matches = RE_NUMBER_STR.match(str)

      # spinel-crass: Spinel's Integer and Rational are 64-bit by default
      # (docs/int-overflow.md; limitations.md, "Rational precision") and
      # raise RangeError past that, where CRuby grows them. A number whose
      # digits and exponent could not be computed exactly in 64 bits is
      # answered as a Float read from its own text -- correctly rounded, so
      # the same Float CRuby's exact value converts to -- and clamped as
      # below. Only the value changes (and only for such a number); repr and
      # raw, which is what Loofah reads, are the text either way.
      unless exact_in_int64?(matches)
        return float_from_parts(matches)
      end

      s = matches[:sign] == '-' ? -1 : 1
      i = matches[:integer].to_i
      f = matches[:fractional].to_i
      d = matches[:fractional] ? matches[:fractional].length : 0
      t = matches[:exponent_sign] == '-' ? -1 : 1
      e = matches[:exponent].to_i

      exponent = t * e

      # Guard against denial of service via attacker-controlled exponentiation.
      # A tiny input like "1e5000000" would otherwise force Ruby to compute
      # `10**exponent` (an enormous integer) before the value is clamped below,
      # consuming disproportionate CPU and memory. When the exponent's magnitude
      # is far outside the range a finite double can represent, we saturate or
      # underflow without performing the exponentiation.
      if i == 0 && f == 0
        # The mantissa is zero, so the value is zero regardless of the exponent.
        value = s * 0.0

      elsif exponent - d > Float::MAX_10_EXP + 1
        # The value is larger than `Float::MAX` and would be clamped anyway.
        value = s * Float::MAX

      elsif exponent + matches[:integer].length < -325
        # The value is smaller than the smallest representable double and would
        # round to zero. (-325 is one less than the smallest subnormal base-10
        # exponent of roughly -324; `matches[:integer].length` is an upper bound
        # on the mantissa's magnitude, ensuring we never zero a representable
        # value.)
        value = s * 0.0

      else
        # I know this formula looks nutty, but it's exactly what's defined in
        # the spec, and it works.
        # spinel-crass: `f * 10**-d` and `10**exponent` as exact Rationals built
        # with a non-negative power. CRuby answers the same Rational either way;
        # Spinel types `10**n` of an int local Integer and raises RangeError
        # for a negative n (docs/limitations.md, "Integer#** with a negative
        # exponent"). The only change to Crass 1.0.7 — see README.
        value = s * (i + Rational(f, 10**d)) * (exponent < 0 ? Rational(1, 10**-exponent) : 10**exponent)

        # Maximum and minimum values aren't defined in the spec, but are
        # enforced here for sanity.
        if value > Float::MAX
          value = Float::MAX
        elsif value < -Float::MAX
          value = -Float::MAX
        end
      end

      value
    end

    # spinel-crass: whether convert_string_to_number's exact arithmetic
    # stays inside 64 bits: the significant integer digits, the fraction's
    # digits and the exponent's magnitude together within 18 digits.
    def exact_in_int64?(matches)
      int_digits = matches[:integer].sub(/\A0+/, '').length
      frac_digits = matches[:fractional] ? matches[:fractional].length : 0
      exp_str = (matches[:exponent] || '').sub(/\A0+/, '')
      return false if exp_str.length > 4

      if frac_digits == 0 && exp_str.empty?
        # A plain integer: exact up to 2**63 - 1.
        digits = matches[:integer].sub(/\A0+/, '')
        return digits.length < 19 || (digits.length == 19 && digits <= '9223372036854775807')
      end
      int_digits + frac_digits + exp_str.to_i <= 18
    end

    # spinel-crass: the number as a Float read from its parts (so any sign,
    # empty integer or empty exponent parses), saturated at Float::MAX as
    # convert_string_to_number's own guards saturate.
    def float_from_parts(matches)
      int_str = matches[:integer].empty? ? '0' : matches[:integer]
      frac_str = matches[:fractional].nil? || matches[:fractional].empty? ? '0' : matches[:fractional]
      exp_str = matches[:exponent].nil? || matches[:exponent].empty? ? '0' : matches[:exponent]
      exp_str = exp_str.sub(/\A0+(?=.)/, '')
      sign = matches[:sign] == '-' ? '-' : ''
      exp_sign = matches[:exponent_sign] == '-' ? '-' : ''

      if exp_str.length > 6
        # Past any double: saturate or underflow without parsing the exponent.
        if exp_sign == '-' || (matches[:integer] + (matches[:fractional] || '')).delete('0').empty?
          return sign == '-' ? -0.0 : 0.0
        end
        return sign == '-' ? -Float::MAX : Float::MAX
      end

      value = "#{sign}#{int_str}.#{frac_str}e#{exp_sign}#{exp_str}".to_f
      if value > Float::MAX
        value = Float::MAX
      elsif value < -Float::MAX
        value = -Float::MAX
      end
      value
    end

    # Creates and returns a new token with the given _properties_.
    def create_token(type, properties = {})
      {
        :node => type,
        :pos  => @s.marker,
        :raw  => @s.marked
      }.merge!(properties)
    end

    # Preprocesses _input_ to prepare it for the tokenizer.
    #
    # 3.3. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#input-preprocessing
    def preprocess(input)
      input = input.to_s.encode('UTF-8',
        :invalid => :replace,
        :undef   => :replace)

      input.gsub!(/(?:\r\n|[\r\f])/, "\n")
      input.gsub!("\u0000", "\ufffd")
      input
    end

    # Returns `true` if the given three-character _text_ would start an
    # identifier. If _text_ is `nil`, the current and next two characters in the
    # input stream will be checked, but will not be consumed.
    #
    # 4.3.10. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#would-start-an-identifier
    def start_identifier?(text = nil)
      text = @s.current + @s.peek(2) if text.nil?

      case text[0]
      when '-'
        nextChar = text[1]
        !!(nextChar == '-' || nextChar =~ RE_NAME_START || valid_escape?(text[1, 2]))

      when RE_NAME_START
        true

      when '\\'
        valid_escape?(text[0, 2])

      else
        false
      end
    end

    # Returns `true` if the given three-character _text_ would start a number.
    # If _text_ is `nil`, the current and next two characters in the input
    # stream will be checked, but will not be consumed.
    #
    # 4.3.11. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#starts-with-a-number
    def start_number?(text = nil)
      text = @s.current + @s.peek(2) if text.nil?

      case text[0]
      when '+', '-'
        !!(text[1] =~ RE_DIGIT || (text[1] == '.' && text[2] =~ RE_DIGIT))

      when '.'
        !!(text[1] =~ RE_DIGIT)

      when RE_DIGIT
        true

      else
        false
      end
    end

    # Tokenizes the input stream and returns an array of tokens.
    def tokenize
      @s.reset

      tokens = []

      while token = consume
        tokens << token
      end

      tokens
    end

    # Returns `true` if the given two-character _text_ is the beginning of a
    # valid escape sequence. If _text_ is `nil`, the current and next character
    # in the input stream will be checked, but will not be consumed.
    #
    # 4.3.9. https://www.w3.org/TR/2013/WD-css-syntax-3-20130919/#starts-with-a-valid-escape
    def valid_escape?(text = nil)
      text = @s.current + @s.peek if text.nil?
      !!(text[0] == '\\' && text[1] != "\n")
    end
  end

end
