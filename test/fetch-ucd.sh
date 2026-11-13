#!/bin/sh
# Downloads the pinned Unicode data the bidi tests and table generator read into test/ucd/ (git-ignored).
# Files are checked against SHA-256 hashes, so a changed upstream file fails loudly instead of silently
# changing what the conformance tests mean. To move to a new Unicode version: change V, then the hashes.
set -eu
cd "$(dirname "$0")"
V=18.0.0
BASE=https://www.unicode.org/Public/$V/ucd
mkdir -p ucd

fetch() { # name path sha256
  if [ -f "ucd/$1" ] && [ "$(shasum -a 256 "ucd/$1" | cut -d' ' -f1)" = "$3" ]; then return; fi
  curl -fsS --retry 3 -o "ucd/$1" "$BASE/$2"
  got=$(shasum -a 256 "ucd/$1" | cut -d' ' -f1)
  [ "$got" = "$3" ] || { echo "ucd/$1: sha256 $got, expected $3" >&2; rm -f "ucd/$1"; exit 1; }
}

fetch BidiTest.txt          BidiTest.txt                     9af2f882a4ab50912e388f069a673b94eacd82fa6d07d20a3ff7f3c759e905aa
fetch BidiCharacterTest.txt BidiCharacterTest.txt            045b24d2c8ab066951bd32fe8c6b4de34647f72b5b1c7df0265f24ab53573e01
fetch BidiBrackets.txt      BidiBrackets.txt                 4b3b62e4a14b84ee752808c810c602534921c09a4a1bf78cfbee566d66c125b3
fetch DerivedBidiClass.txt  extracted/DerivedBidiClass.txt   d9e23222522551348ea1ccfbb4f62efbf98982afb95840f8959c08ed992c5607
