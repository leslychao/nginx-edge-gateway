#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
for script in scripts/*.sh tests/*.sh; do sh -n "$script"; done
mkdir -p .work
lint_dir=$(mktemp -d "$ROOT/.work/lint.XXXXXX")
cp -R scripts tests deploy "$lint_dir/"
set --
for script in scripts/*.sh tests/*.sh; do set -- "$@" "/work/$script"; done
lint_container=$(docker create --workdir /work "$SHELLCHECK_IMAGE" -x -P /work/scripts --shell=sh "$@")
trap 'docker rm "$lint_container" >/dev/null; rm -rf "$lint_dir"' EXIT
# Docker cp works with a remote daemon; a bind mount of this checkout would not.
docker cp ".work/${lint_dir##*/}/." "$lint_container:/work"
docker start -a "$lint_container"
lint_exit=$(docker inspect --format '{{.State.ExitCode}}' "$lint_container")
[ "$lint_exit" = 0 ] || fail 'ShellCheck failed'
compose config --quiet
git diff --check
if git ls-files | grep -E '\.(pem|key|p12|pfx|secrets)$'; then fail 'Secret/certificate file is tracked'; fi
printf '%s\n' 'Shell syntax, ShellCheck, Compose and tracked-file checks passed.'
