#!/bin/sh
# Oracle harness: run the test programs under CRuby with the REAL crass
# gem and diff against the committed snapshots. `-I` is not passed, so
# `require "crass"` resolves to the gem, not this package — and since
# this package IS the gem's source, unmodified, the point of the snapshot
# is what the compiled program must print, not a port's fidelity.
#
# Usage: sh oracle/run.sh           (from the repo root)
#        sh oracle/run.sh --regen   (rewrite the snapshots from the gem)
# Needs: ruby with the crass gem (gem install crass -v 1.0.7).

OUTDIR=build/oracle
mkdir -p "$OUTDIR"
fails=0
ran=0
for t in test/*_test.rb; do
  name=$(basename "$t" .rb)
  ruby -e 'gem "crass", "1.0.7"' -e "load '$t'" > "$OUTDIR/$name.out" 2>&1
  ran=$((ran + 1))
  if [ "$1" = "--regen" ]; then
    cp "$OUTDIR/$name.out" "$t.expected"
    echo "regen $name"
  elif diff -u "$t.expected" "$OUTDIR/$name.out" > "$OUTDIR/$name.diff" 2>&1; then
    echo "ok   $name"
    rm -f "$OUTDIR/$name.diff"
  else
    echo "FAIL $name (see $OUTDIR/$name.diff)"
    fails=$((fails + 1))
  fi
done
echo "$((ran - fails))/$ran match crass"
[ $fails -eq 0 ]
