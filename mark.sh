#!/bin/sh
exec gawk -f "$0" -- "$@"

BEGIN {
    print "Hello, world!"
}

