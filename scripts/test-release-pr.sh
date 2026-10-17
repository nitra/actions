#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
action_script="$(ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/forgejo-create-release-pr/action.yml")"
real_git="$(command -v git)"
mkdir "$test_dir/bin"
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
  *'-X POST'*) printf 'POST\n' >> "$CURL_LOG"; printf '{}' ;;
  *) printf '%s' "$EXISTING_PRS" ;;
esac
EOF
cat > "$test_dir/bin/git" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
  *' push '*)
    if [ -n "${RACE_TARGET:-}" ]; then
      "$REAL_GIT" --git-dir="$RACE_REMOTE" update-ref refs/heads/release/v1.0.1 "$RACE_TARGET"
    fi
    ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$test_dir/bin/curl" "$test_dir/bin/git"

init_repo() {
  repo="$test_dir/$1"
  git init -q "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  mkdir -p "$repo/app/.changes"
  printf 'keep\n' > "$repo/app/.changes/.gitkeep"
  printf 'first change\n' > "$repo/app/.changes/first.md"
  printf '1.0.0\n' > "$repo/app/version"
  git -C "$repo" add .
  git -C "$repo" commit -qm initial
  git -C "$repo" branch -M main
  git init -q --bare "$repo/remote.git"
  git -C "$repo" remote add origin "$repo/remote.git"
  git -C "$repo" push -q origin main
  : > "$repo/curl.log"
}

prepare() {
  printf '1.0.1\n' > "$repo/app/version"
  rm -f "$repo/app/.changes/first.md" "$repo/app/.changes/second.md"
}

run_action() {
  (
    cd "$repo"
    TOKEN=dummy SERVER_URL=https://forgejo.example REPOSITORY=owner/repo \
      TAG=v1.0.1 BASE=main COMMIT_MESSAGE='chore(release): v1.0.1' \
      PATHS="$(printf 'app/version\napp/.changes')" \
      CURL_LOG="$repo/curl.log" EXISTING_PRS="$existing_prs" \
      REAL_GIT="$real_git" RACE_REMOTE="$repo/remote.git" \
      PATH="$test_dir/bin:$PATH" sh -c "$action_script"
  )
}

remote_head() {
  git --git-dir="$repo/remote.git" rev-parse refs/heads/release/v1.0.1
}

reject_action() {
  if run_action; then
    echo 'Expected release preparation to fail.' >&2
    exit 1
  fi
}

existing_prs='[]'
init_repo refresh
prepare
run_action
first="$(remote_head)"
test "$(cat "$repo/curl.log")" = POST
test "$(git -C "$repo" show "$first:app/version")" = 1.0.1
if git -C "$repo" cat-file -e "$first:app/.changes/first.md" 2>/dev/null; then exit 1; fi
test "$(git -C "$repo" rev-parse "$first^")" = "$(git -C "$repo" rev-parse HEAD)"

# A matching existing PR is reused, and identical preparation is a no-op.
existing_prs='[{"head":{"ref":"release/v1.0.1"}}]'
: > "$repo/curl.log"
run_action
test "$(remote_head)" = "$first"
test ! -s "$repo/curl.log"

# Main has new code and a new change file. Regenerate from main, not from the
# old bumped tree, consume both changes, and keep the existing PR number.
git -C "$repo" restore --staged --worktree app
printf 'second change\n' > "$repo/app/.changes/second.md"
printf 'new code\n' > "$repo/app/code"
git -C "$repo" add app
git -C "$repo" commit -qm 'fix: new code'
git -C "$repo" push -q origin main
prepare
run_action
second="$(remote_head)"
test "$second" != "$first"
test "$(git -C "$repo" show "$second:app/code")" = 'new code'
test "$(git -C "$repo" rev-parse "$second^")" = "$(git -C "$repo" rev-parse HEAD)"
test "$(git -C "$repo" ls-tree --name-only "$second:app/.changes")" = .gitkeep
test ! -s "$repo/curl.log"

# The refreshed branch retains exactly one release commit, so its PR merge
# remains accepted by the downstream protected tag-and-dispatch gate.
git -C "$repo" restore --staged --worktree app
git -C "$repo" merge --no-ff -qm 'Merge release PR' "$second"
tag_script="$(ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/forgejo-tag-and-dispatch/action.yml")"
(
  cd "$repo"
  TOKEN=dummy SERVER_URL=https://forgejo.example REPOSITORY=owner/repo \
    TAG=v1.0.1 WORKFLOW=release.yml EXPECTED='chore(release): v1.0.1' \
    CURL_LOG="$repo/curl.log" PATH="$test_dir/bin:$PATH" REAL_GIT="$real_git" sh -c "$tag_script"
)
test "$(git -C "$repo" rev-parse 'v1.0.1^{}')" = "$(git -C "$repo" rev-parse HEAD)"
# Restore the unmerged main fixture before checking protection of manual edits.
git -C "$repo" switch -q -C main "$second^"

# A manual commit is never discarded, even inside an allowed release path.
git -C "$repo" restore --staged --worktree app
git -C "$repo" switch -qc manual "$second"
printf 'manual version\n' > "$repo/app/version"
git -C "$repo" add app/version
git -C "$repo" commit -qm 'fix: manual release edit'
git -C "$repo" push -q origin HEAD:release/v1.0.1
manual="$(remote_head)"
git -C "$repo" switch -q main
prepare
reject_action
test "$(remote_head)" = "$manual"

# A sole bot commit with the right subject but unexpected files also fails.
init_repo unexpected
git -C "$repo" switch -qc release/v1.0.1
printf 'manual code\n' > "$repo/unexpected"
git -C "$repo" add unexpected
git -C "$repo" -c user.email='forgejo-actions[bot]@users.noreply.git.7n.ai' commit -qm 'chore(release): v1.0.1'
git -C "$repo" push -q origin release/v1.0.1
unexpected="$(remote_head)"
git -C "$repo" switch -q main
prepare
reject_action
test "$(remote_head)" = "$unexpected"

# Unrelated staged changes cannot leak into the release tree.
init_repo index
prepare
printf 'unrelated\n' > "$repo/unrelated"
git -C "$repo" add unrelated
reject_action
if git --git-dir="$repo/remote.git" show-ref --verify --quiet refs/heads/release/v1.0.1; then exit 1; fi

# A stale workflow must not replace a newer preparation from current main.
init_repo stale
printf 'new code\n' > "$repo/app/code"
git -C "$repo" add app
git -C "$repo" commit -qm 'fix: newer main'
git -C "$repo" push -q origin main
git -C "$repo" checkout -q HEAD^
prepare
reject_action

# A competitor winning between fetch and push is preserved by the exact lease.
init_repo race
existing_prs='[]'
prepare
run_action
git -C "$repo" restore --staged --worktree app
printf 'new code\n' > "$repo/app/code"
git -C "$repo" add app
git -C "$repo" commit -qm 'fix: concurrent main'
git -C "$repo" push -q origin main
prepare
RACE_TARGET="$(git -C "$repo" rev-parse HEAD)" reject_action
test "$(remote_head)" = "$(git -C "$repo" rev-parse HEAD)"

# The empty lease also prevents a race during initial branch creation.
init_repo create-race
prepare
RACE_TARGET="$(git -C "$repo" rev-parse HEAD)" reject_action
test "$(remote_head)" = "$(git -C "$repo" rev-parse HEAD)"
test ! -s "$repo/curl.log"

# A matching subject alone is insufficient: preserve human-authored branches.
init_repo author
git -C "$repo" switch -qc release/v1.0.1
prepare
git -C "$repo" add app
git -C "$repo" commit -qm 'chore(release): v1.0.1'
git -C "$repo" push -q origin release/v1.0.1
human="$(remote_head)"
git -C "$repo" switch -q main
prepare
reject_action
test "$(remote_head)" = "$human"

# A bot-authored unrelated commit cannot be replaced either.
init_repo subject
git -C "$repo" switch -qc release/v1.0.1
prepare
git -C "$repo" add app
git -C "$repo" -c user.email='forgejo-actions[bot]@users.noreply.git.7n.ai' commit -qm 'fix: unrelated bot edit'
git -C "$repo" push -q origin release/v1.0.1
unrelated="$(remote_head)"
git -C "$repo" switch -q main
prepare
reject_action
test "$(remote_head)" = "$unrelated"

# Duplicate matching PRs fail before any branch creation or API mutation.
init_repo duplicate
existing_prs='[{"head":{"ref":"release/v1.0.1"}},{"head":{"ref":"release/v1.0.1"}}]'
prepare
reject_action
if git --git-dir="$repo/remote.git" show-ref --verify --quiet refs/heads/release/v1.0.1; then exit 1; fi
test ! -s "$repo/curl.log"

# Do not publish an empty release preparation.
init_repo empty
existing_prs='[]'
reject_action
if git --git-dir="$repo/remote.git" show-ref --verify --quiet refs/heads/release/v1.0.1; then exit 1; fi

printf 'Release PR creation, refresh, reuse, idempotence and safety checks passed.\n'
