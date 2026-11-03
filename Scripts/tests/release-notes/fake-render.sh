#!/bin/sh
# Stands in for GitHub's markdown API in the fixture test: every input line becomes a <p>.
sed 's/^\(..*\)$/<p>\1<\/p>/'
