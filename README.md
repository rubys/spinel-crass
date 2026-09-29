# crass (spinel-crass)

[Crass](https://github.com/rgrove/crass), Ryan Grove's CSS parser, for
Spinel: the gem's own source, **not a port**. `crass.rb` and
`crass/*.rb` are Crass 1.0.7 byte for byte, except two changes in one method (below).
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

## The two changes

Both are in `Tokenizer#convert_string_to_number` (and one line of
`consume_numeric`), marked `# spinel-crass:`. Every other file is
`cmp`-identical to the gem.

**1. Exact Rationals built with non-negative powers.** Crass computes the
spec's formula as

```ruby
value = s * (i + f * 10**-d) * 10**exponent
```

In CRuby, `10**-d` is a `Rational`. Spinel types `**` on an int local as
`Integer` and raises `RangeError` for a negative exponent at run time
(`docs/limitations.md`, "`Integer#**` with a negative exponent"), so any
decimal (`1.5`) or negative exponent (`1e-3`) raised. The carried line
builds the same `Rational`:

```ruby
value = s * (i + Rational(f, 10**d)) * (exponent < 0 ? Rational(1, 10**-exponent) : 10**exponent)
```

**2. Past 64 bits, a Float.** Spinel's `Integer` and `Rational` are 64-bit
by default and raise `RangeError` past that (`docs/int-overflow.md`;
`limitations.md`, "`Rational` precision"). Even `--int-overflow=promote`
leaves `Rational` at 64 bits, and a library cannot choose the mode anyway.
Crass already guards this function against exponents too large to
compute, saturating to `Float::MAX` or `0.0`. The change extends that
guard: a number whose digits and exponent cannot be computed exactly in
64 bits (`12345678901234567890px`, `1234567890.123456789e-10`,
`1e99999999999999999999`) is read as a Float from its own text, and
clamped the same way.

- For a `:number` that Float is the one CRuby's exact value converts to,
  since both are correctly rounded.
- For an `:integer` past 2**63, `:value` is that Float where CRuby's is a
  Bignum.
- `:repr` and `:raw`, which are what `stringify` and Loofah use, are the
  text either way.

Without this, a `style` value with such a number raised inside the
sanitizer instead of being scrubbed.

## Known gaps

- **An integer past 2**63:** its `:value` is a Float, not a Bignum (see
  above).

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
  `!important`, escapes, huge and tiny exponents, and numbers past 64
  bits. Integers past 2**63 print only their text fields, since their
  `:value` differs by design.

The snapshots come from the gem. None are written by hand.

All three match the gem on Spinel master 1963b7732.
