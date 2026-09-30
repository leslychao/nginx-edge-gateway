#!/bin/sh
set -eu
export EDGE_ENV=dev
exec sh "$(dirname "$0")/certificates.sh" renew
