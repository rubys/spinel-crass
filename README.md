# crass (spinel-crass)

[Crass](https://github.com/rgrove/crass), Ryan Grove's CSS parser, for
Spinel: the gem's own source, **not a port**. `crass.rb` and
`crass/*.rb` are Crass 1.0.7 byte for byte, except one expression (below).
`require "crass"` and the names are the gem's.

It is here because Loofah's `style`-attribute scrubber (and so
rails-html-sanitizer's, and Action Text's) parses CSS with it.

```ruby
require "crass"

tree = Crass.parse_properties("color: red; background: url(x.png)")
Crass::Parser.stringify(tree)                     # => "color: red; background: url(x.png)"
Crass.parse(css, preserve_comments: true)         # a whole stylesheet
Crass::Parser.new("url(#a) #b").parse_component_values
```

## The one change

`Tokenizer#convert_string_to_number` computes the spec's formula as

```ruby
value = s * (i + f * 10**-d) * 10**exponent
```

In CRuby, `10**-d` is a `Rational`. Spinel types `**` on an int local as
`Integer` and raises `RangeError` for a negative exponent at run time.
That is a deliberate subset line, described in Spinel's
`docs/limitations.md` under "`Integer#**` with a negative exponent". So
any decimal (`1.5`) or negative exponent (`1e-3`) raised. The carried
line builds the same `Rational` with non-negative powers:

```ruby
value = s * (i + Rational(f, 10**d)) * (exponent < 0 ? Rational(1, 10**-exponent) : 10**exponent)
```

CRuby gives the same value from both lines, and the tests below show it.
Every other file is `cmp`-identical to the gem.

## Known gaps

- **A CSS number beyond int64 raises `RangeError`.** This covers an
  integer part over 19 digits, and a decimal whose exact value needs a
  denominator over 2**63 (`1234567890.123456789e-10`). Spinel's `Integer`
  and `Rational` are 64-bit by default (`docs/int-overflow.md`), and CRuby
  would grow them. Under Loofah this means a `style` value with such a
  number raises instead of being scrubbed.

## Tests

```sh
spin test                    # the compiled package against the snapshots
sh oracle/run.sh             # the same programs under CRuby with the real gem
ruby oracle/generate.rb      # rebuild the programs from oracle/data
sh oracle/run.sh --regen     # re-take the snapshots from the gem
```

The inputs are the corpora Crass's own suite uses:

- **css-parsing-tests**, Simon Sapin's (`component_value_list`,
  `declaration_list`, `one_declaration`; licence in `oracle/data`). Each
  parse tree is printed whole.
- **Three real stylesheets**, which must round-trip through `parse` and
  `stringify` to the same bytes.
- **The `style` values Loofah passes in:** `url()`, `expression()`,
  `!important`, escapes, huge and tiny exponents.

The snapshots come from the gem. None are written by hand.

`parse_test` currently differs from the gem in one place, the inspect of
two tokens holding U+0080/U+0081. That is Spinel's `String#inspect`
([spinel#5984](https://github.com/matz/spinel/issues/5984)), not Crass:
the tokens themselves are right.
