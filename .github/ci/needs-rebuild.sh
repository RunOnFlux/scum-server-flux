#!/bin/bash
# Does the scheduled run have anything new to publish?
#
#   .github/ci/needs-rebuild.sh <image> <base image>
#
# Writes to $GITHUB_OUTPUT:
#   base_digest  the base image's digest now, which the build pins and records in a label
#   build        true or false
#
# A push or a manual run always builds. A SCHEDULED run builds only when there is something to
# apply, because every image published as :latest restarts every server running it (FluxOS
# compares each app's tag digest every six hours and soft-redeploys onto a new one, with no
# warning in game), and a rebuild of unchanged inputs still gets a new digest.
#
# Two things make a scheduled run build NOW (a third waits for the monthly rebuild):
#   1. a security update for a package the server really runs on is waiting (below), or
#   2. main has commits the published image does not have: the published :latest records the commit
#      it was built from (label org.opencontainers.image.revision), and at least one commit since
#      then touches an image INPUT (the Dockerfile, VERSION, every path a COPY/ADD takes). README,
#      tests and .github changes do not count. A published image with no revision label counts as
#      pending (one extra rebuild, after which it is labelled). Needs the full git history
#      (actions/checkout fetch-depth: 0).
#
# What counts for 1., measured on 2026-10-16: steamcmd/steamcmd:ubuntu-24 is republished almost daily,
# and an image published that morning already had security updates waiting, for libsystemd0 and
# libudev1, which nothing in a game server's container uses. Building on every such change would
# restart every server every week again. So:
#   now           a security update is waiting in the published image for a package the server
#                 really runs on (URGENT below: the C library, TLS, certificates, curl, Python for
#                 the supervisor, zlib, the C++ runtime, Wine, .NET)
#   monthly       anything else, on the first Monday of the month: the base image moved since the
#                 published :latest (its digest differs from the org.opencontainers.image.base.digest
#                 label), or any other update is waiting
#   otherwise     nothing: :latest stays, and no server restarts
set -euo pipefail

image="${1:?image}"
base="${2:?base image}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

base_digest="$(docker buildx imagetools inspect "${base}" --format '{{json .Manifest}}' | jq -r '.digest')"
[[ "${base_digest}" == sha256:* ]] || { echo "::error::could not resolve ${base}"; exit 1; }
echo "base_digest=${base_digest}" >>"${out}"
echo "base ${base} is ${base_digest}"

if [ "${GITHUB_EVENT_NAME:-}" != "schedule" ]; then
  echo "build=true" >>"${out}"
  echo "a ${GITHUB_EVENT_NAME:-manual} run: building"
  exit 0
fi

# Packages whose security updates are applied the same week.
URGENT='^(libc6|libc-bin|libssl[0-9a-z.]*|openssl|ca-certificates|curl|libcurl[0-9a-z.-]*|libgnutls[0-9a-z.]*|libnghttp2-[0-9a-z]*|zlib1g|python3(\.[0-9]+)?(-minimal)?|libpython3(\.[0-9]+)?(-minimal|-stdlib)?|libstdc\+\+6|libgcc-s1|wine[a-z0-9-]*|winehq[a-z0-9-]*|dotnet[a-z0-9.-]*|aspnetcore[a-z0-9.-]*)(:[a-z0-9]+)?$'
monthly=false
[ "$(date -u +%d)" -le 7 ] && monthly=true

now=()
later=()

# A label of the published image (one platform, or the amd64 entry of a multi-platform one).
published_label() {
  docker buildx imagetools inspect "${image}:latest" --format '{{json .Image}}' 2>/dev/null \
    | jq -r --arg k "$1" 'if has("config") then . else ([to_entries[] | select(.key | test("amd64")) | .value][0] // {}) end
                          | .config.Labels[$k] // empty' || true
}
recorded="$(published_label org.opencontainers.image.base.digest)"
if [ -z "${recorded}" ]; then
  echo "the published ${image}:latest records no base digest (built before this check)"
  later+=("the base digest of the published image is not recorded")
elif [ "${recorded}" != "${base_digest}" ]; then
  later+=("the base moved: ${recorded} -> ${base_digest}")
else
  echo "the base has not moved since the published image"
fi

# Commits on main the published image does not have (2. above).
head_sha="$(git rev-parse HEAD)"
revision="$(published_label org.opencontainers.image.revision)"
pending=false
inputs=(Dockerfile VERSION)
while read -r line; do
  read -ra words <<<"${line}"
  words=("${words[@]:1}")
  sources=()
  for w in "${words[@]}"; do
    [[ "${w}" == --* ]] || sources+=("${w}")
  done
  unset 'sources[${#sources[@]}-1]'
  inputs+=("${sources[@]}")
done < <(grep -E '^(COPY|ADD)[[:space:]]' Dockerfile | grep -v -- '--from=' || true)
if [ -z "${revision}" ]; then
  pending=true
  now+=("the published image records no revision (built before this check): pending")
elif [ "${revision}" = "${head_sha}" ]; then
  echo "the published image was built from HEAD (${head_sha:0:12})"
elif ! git cat-file -e "${revision}^{commit}" 2>/dev/null; then
  pending=true
  now+=("the published revision ${revision:0:12} is not in this checkout's history: pending")
else
  ahead="$(git rev-list --count "${revision}..${head_sha}" -- "${inputs[@]}")"
  if [ "${ahead}" -gt 0 ]; then
    pending=true
    now+=("${ahead} commit(s) since the published ${revision:0:12} touch the image inputs (${inputs[*]})")
  else
    echo "no commit since the published ${revision:0:12} touches the image inputs (${inputs[*]})"
  fi
fi
echo "pending=${pending}"

# Updates the published image is missing, as root (the image may run as another user).
# "Inst <package> [<installed>] (<candidate> <origin> ..." per package.
# Only Ubuntu's own archive counts: a package pinned on purpose from another one (V Rising's Wine
# from WineHQ) always has a newer version there, and would ask for a rebuild that changes nothing.
# The build runs apt-get upgrade, so what a rebuild applies is exactly what is listed here.
updates="$(docker run --rm --pull always --user 0 --entrypoint sh "${image}:latest" -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep "^Inst " | grep " Ubuntu:"' || true)"
security="$(grep -- '-security' <<<"${updates}" | awk '{print $2}' || true)"
urgent="$(grep -E "${URGENT}" <<<"${security}" || true)"
other="$(grep -c . <<<"${updates}" || true)"
if [ -n "${urgent}" ]; then
  now+=("security updates for $(tr '\n' ' ' <<<"${urgent}")")
fi
if [ "${other:-0}" -gt 0 ]; then
  echo "waiting in the published image: $(awk '{print $2}' <<<"${updates}" | tr '\n' ' ')"
  later+=("${other} package update(s) are waiting")
fi

if [ "${#now[@]}" -gt 0 ]; then
  printf 'building now: %s\n' "${now[@]}"
  echo "build=true" >>"${out}"
elif [ "${#later[@]}" -gt 0 ] && [ "${monthly}" = true ]; then
  printf 'building (the monthly rebuild): %s\n' "${later[@]}"
  echo "build=true" >>"${out}"
elif [ "${#later[@]}" -gt 0 ]; then
  printf 'left for the monthly rebuild (first Monday): %s\n' "${later[@]}"
  echo "build=false" >>"${out}"
else
  echo "nothing new: ${image}:latest stays as it is, and no server restarts"
  echo "build=false" >>"${out}"
fi
