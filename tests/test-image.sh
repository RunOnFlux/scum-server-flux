#!/bin/bash
# Tests against a BUILT image: what the unit tests cannot see, because they run the scripts with
# the machine's own Python and tools, not the image's.
#
#   ./tests/test-image.sh [image]        default scum-server-flux:local
#
# No Steam, no Wine run and no game: tests/image/in-container.sh puts a stand-in steamcmd and a
# stand-in server in the container and runs the real supervisor around them. CI runs this BEFORE
# it publishes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

image="${1:-scum-server-flux:local}"
docker run --rm --entrypoint bash -v "${PWD}/tests:/t:ro" -v "${PWD}/scripts:/s:ro" "${image}" /t/image/in-container.sh
