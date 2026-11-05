#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
action_script="$(ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/conventional-release-version/action.yml")"

output="$test_dir/output"
log="$test_dir/log"

init_repo() {
  repo="$test_dir/$1"
  git init -q "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  printf 'initial\n' > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm 'chore: initial'
  git -C "$repo" branch -M main
}

commit() {
  printf '%s\n' "$1" >> "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm "$1"
}

commit_body() {
  printf '%s\n' "$1" >> "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm "$1" -m "$2"
}

# Runs the action step exactly as a runner would: fresh GITHUB_OUTPUT, all
# step output captured so diagnostics can be asserted.
run_action() {
  : > "$output"
  (
    cd "$repo"
    CURRENT_VERSION="$1" REQUESTED_VERSION="${2-}" TAG_PREFIX="${3-v}" \
      GITHUB_OUTPUT="$output" sh -c "$action_script"
  ) > "$log" 2>&1
}

reject_action() {
  if run_action "$@"; then
    echo "Expected version selection to fail for current-version=$1 requested-version=${2-} tag-prefix=${3-v}." >&2
    cat "$log" >&2
    exit 1
  fi
  # A rejection must never leave a half-written decision behind.
  if [ -s "$output" ]; then
    echo 'Expected no step output on failure.' >&2
    cat "$output" >&2
    exit 1
  fi
  # Every refusal also has to reach the job annotations, not only the raw log.
  grep -q '^::error::conventional-release-version: ' "$log" || {
    echo 'Expected an ::error:: annotation on failure.' >&2
    cat "$log" >&2
    exit 1
  }
}

assert_output() {
  for expected in "$@"; do
    grep -Fqx -- "$expected" "$output" || {
      echo "Missing step output: $expected" >&2
      cat "$output" >&2
      exit 1
    }
  done
}

# Every refusal and every non-obvious decision must name the cause in the log;
# a bare exit 1 has twice cost hours of release debugging.
assert_log() {
  for expected in "$@"; do
    grep -Fq -- "$expected" "$log" || {
      echo "Missing diagnostic: $expected" >&2
      cat "$log" >&2
      exit 1
    }
  done
}

# A feat commit after the matching release tag is a minor bump.
init_repo minor
git -C "$repo" tag v1.2.3
commit 'feat: new capability'
run_action 1.2.3
assert_output release=true version=1.3.0 tag=v1.3.0 bump=minor
assert_log 'Selected minor release v1.3.0' 'latest release tag v1.2.3'

# fix and perf are patches; an unrelated chore does not raise the bump.
init_repo patch
git -C "$repo" tag v1.2.3
commit 'chore: housekeeping'
commit 'perf: faster path'
run_action 1.2.3
assert_output release=true version=1.2.4 tag=v1.2.4 bump=patch

# A bang subject is a major bump even without a body.
init_repo major-bang
git -C "$repo" tag v1.2.3
commit 'feat(api)!: drop legacy field'
run_action 1.2.3
assert_output release=true version=2.0.0 tag=v2.0.0 bump=major

# A BREAKING CHANGE footer is a major bump too.
init_repo major-footer
git -C "$repo" tag v1.2.3
commit_body 'fix: tighten validation' 'BREAKING CHANGE: rejects previously accepted input'
run_action 1.2.3
assert_output release=true version=2.0.0 tag=v2.0.0 bump=major

# No releasable commit is a normal outcome, but it must say why.
init_repo no-release
git -C "$repo" tag v1.2.3
commit 'chore: housekeeping'
commit 'docs: explain usage'
run_action 1.2.3
test "$(cat "$output")" = release=false
assert_log 'No feat, fix, perf, or breaking commit among 2 commit(s) since v1.2.3'

# Without any release tag the current version is the initial release, and the
# log says so: a tagless checkout is otherwise indistinguishable from a repo
# that genuinely has no release yet.
init_repo initial
commit 'feat: new capability'
run_action 0.1.0
assert_output release=true version=0.1.0 tag=v0.1.0 bump=initial
assert_log 'No vMAJOR.MINOR.PATCH tag is merged into HEAD' 'fetch the full history including tags'

# Tags of another prefix series must not be mistaken for this one.
init_repo other-prefix
git -C "$repo" tag v1.2.3
commit 'feat: new capability'
run_action 0.1.0 '' app
assert_output release=true version=0.1.0 tag=app0.1.0 bump=initial

# A requested version short-circuits the commit scan.
init_repo manual
git -C "$repo" tag v1.2.3
commit 'chore: housekeeping'
run_action 1.2.3 2.5.0
assert_output release=true version=2.5.0 tag=v2.5.0 bump=manual
assert_log 'Selected manual release v2.5.0'

# A requested version is accepted even with no tags and no releasable commit.
init_repo manual-initial
run_action 0.1.0 1.0.0
assert_output release=true version=1.0.0 tag=v1.0.0 bump=manual

# The state that cost hours on 7n/rules: the version was bumped in the
# repository but never tagged, so the latest merged tag is behind it. The
# refusal stands, yet it must report both versions and the missing tag.
init_repo ahead-untagged
git -C "$repo" tag v1.2.3
commit 'feat: new capability'
reject_action 1.3.0
assert_log \
  'current-version 1.3.0 does not match the latest release tag v1.2.3 merged into HEAD (version 1.2.3)' \
  'Tag v1.3.0 does not exist' \
  'set current-version to 1.2.3'
# The only way out that actually ships this version has to be spelled out,
# including why retrying the tagging job instead is useless.
assert_log \
  'dispatch the release workflow manually (workflow_dispatch) with version=1.3.0' \
  'Re-running tag-release will not help'
# A GitHub annotation is one line: the continuation lines must be folded, or
# everything after the first is lost from the summary.
assert_log '::error::conventional-release-version: current-version 1.3.0 does not match the latest release tag v1.2.3 merged into HEAD (version 1.2.3).%0AThis action bumps the released version'

# The same mismatch with the tag present but unmerged is a different fix, so it
# must get a different instruction.
init_repo ahead-unmerged
git -C "$repo" tag v1.2.3
git -C "$repo" switch -qc released
commit 'feat: released elsewhere'
git -C "$repo" tag v1.3.0
git -C "$repo" switch -q main
commit 'fix: unrelated work'
reject_action 1.3.0
assert_log \
  'current-version 1.3.0 does not match the latest release tag v1.2.3 merged into HEAD (version 1.2.3)' \
  'Tag v1.3.0 exists but is not merged into HEAD'

# A version behind the latest tag is the same class of refusal.
init_repo behind
git -C "$repo" tag v1.2.3
commit 'feat: new capability'
reject_action 1.0.0
assert_log \
  'current-version 1.0.0 does not match the latest release tag v1.2.3 merged into HEAD (version 1.2.3)' \
  'Tag v1.0.0 does not exist'

# Malformed inputs are rejected by name, with the offending value quoted.
init_repo inputs
git -C "$repo" tag v1.2.3
commit 'feat: new capability'

reject_action v1.2.3
assert_log "current-version 'v1.2.3' is not a strict SemVer version"
reject_action 1.2
assert_log "current-version '1.2' is not a strict SemVer version"
reject_action 1.2.3-rc.1
assert_log "current-version '1.2.3-rc.1' is not a strict SemVer version"
reject_action ' 1.2.3'
assert_log "current-version ' 1.2.3' is not a strict SemVer version"
reject_action ''
assert_log "current-version '' is not a strict SemVer version"
# A percent sign in an echoed value would truncate the annotation unless it is
# escaped; stderr still shows it verbatim.
reject_action '1.2.3%0Afoo'
assert_log \
  "current-version '1.2.3%0Afoo' is not a strict SemVer version" \
  "::error::conventional-release-version: current-version '1.2.3%250Afoo' is not"

reject_action 1.2.3 '' ''
assert_log "tag-prefix '' is not a usable release tag prefix"
reject_action 1.2.3 '' 'v/'
assert_log "tag-prefix 'v/' is not a usable release tag prefix"

reject_action 1.2.3 v2.0.0
assert_log "requested-version 'v2.0.0' is not a strict SemVer version"
reject_action 1.2.3 2.0
assert_log "requested-version '2.0' is not a strict SemVer version"
reject_action 1.2.3 2.0.0-rc.1
assert_log "requested-version '2.0.0-rc.1' is not a strict SemVer version"
assert_log 'Leave requested-version empty'

printf 'Conventional release version selection and diagnostics checks passed.\n'
