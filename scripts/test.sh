#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

for action in "$root"/*/action.yml; do
  ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$action"
  ruby -ryaml -e '
    doc = YAML.load_file(ARGV.fetch(0))
    doc.fetch("runs").fetch("steps", []).each { |step| puts step["run"] if step["run"] }
  ' "$action" | sh -n
done

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

git -C "$test_dir" init -q
git -C "$test_dir" config user.name test
git -C "$test_dir" config user.email test@example.invalid
touch "$test_dir/file"
git -C "$test_dir" add file
git -C "$test_dir" commit -qm initial
git -C "$test_dir" tag v1.2.3
printf '%s\n' change >> "$test_dir/file"
git -C "$test_dir" add file
git -C "$test_dir" commit -qm 'feat: test conventional version action'

output="$test_dir/output"
conventional_script="$(ruby -ryaml -e 'doc = YAML.load_file(ARGV.fetch(0)); puts doc.fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/conventional-release-version/action.yml")"
(
  cd "$test_dir"
  CURRENT_VERSION=1.2.3 REQUESTED_VERSION='' TAG_PREFIX=v GITHUB_OUTPUT="$output" sh -c "$conventional_script"
)
grep -Fx 'release=true' "$output"
grep -Fx 'version=1.3.0' "$output"
grep -Fx 'tag=v1.3.0' "$output"
grep -Fx 'bump=minor' "$output"

version_script="$(ruby -ryaml -e 'doc = YAML.load_file(ARGV.fetch(0)); puts doc.fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/cargo-set-package-version/action.yml")"
manifest="$test_dir/Cargo.toml"
lockfile="$test_dir/Cargo.lock"
cat > "$manifest" <<'EOF'
[package]
name = "example"
version = "1.2.3"
EOF
cat > "$lockfile" <<'EOF'
version = 4

[[package]]
name = "example"
version = "1.2.3"
EOF
(
  MANIFEST_PATH="$manifest" PACKAGE_NAME=example VERSION=1.3.0 LOCKFILE_PATH="$lockfile" sh -c "$version_script"
)
grep -Fx 'version = "1.3.0"' "$manifest"
grep -Fx 'version = "1.3.0"' "$lockfile"
MANIFEST_PATH="$manifest" PACKAGE_NAME=missing VERSION=1.4.0 LOCKFILE_PATH="$lockfile" sh -c "$version_script" && exit 1
grep -Fx 'version = "1.3.0"' "$manifest"

git -C "$test_dir" init -q --bare "$test_dir/remote.git"
git -C "$test_dir" remote add origin "$test_dir/remote.git"
printf '%s\n' next >> "$test_dir/file"
commit_script="$(ruby -ryaml -e 'doc = YAML.load_file(ARGV.fetch(0)); puts doc.fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/git-commit-tag-push/action.yml")"
(
  cd "$test_dir"
  TOKEN=dummy BRANCH=main TAG=v1.3.0 PATHS=file COMMIT_MESSAGE='release v1.3.0' AUTHOR_NAME=bot AUTHOR_EMAIL=bot@example.invalid sh -c "$commit_script"
)
test "$(git -C "$test_dir" log -1 --format=%s)" = 'release v1.3.0'
test "$(git -C "$test_dir/remote.git" rev-parse refs/heads/main)" = "$(git -C "$test_dir" rev-parse HEAD)"
test -n "$(git -C "$test_dir/remote.git" rev-parse refs/tags/v1.3.0)"

tag_dispatch_script="$(ruby -ryaml -e 'doc = YAML.load_file(ARGV.fetch(0)); puts doc.fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/forgejo-tag-and-dispatch/action.yml")"
tag_mock_bin="$test_dir/tag-mock-bin"
mkdir "$tag_mock_bin"
tag_curl_log="$test_dir/tag-curl.log"
cat > "$tag_mock_bin/curl" <<'EOF'
#!/bin/sh
set -eu

printf '%s\n' "$*" >> "$TAG_CURL_LOG"
EOF
chmod +x "$tag_mock_bin/curl"

init_tag_repo() {
  repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  printf '%s\n' initial > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm initial
  git -C "$repo" branch -M main
  git -C "$repo" init -q --bare "$repo/remote.git"
  git -C "$repo" remote add origin "$repo/remote.git"
  git -C "$repo" push -qu origin main
}

release_commit() {
  repo="$1"
  subject="$2"
  printf '%s\n' "$subject" >> "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm "$subject"
}

run_tag_dispatch() {
  repo="$1"
  tag="$2"
  expected="$3"
  (
    cd "$repo"
    TOKEN=dummy SERVER_URL=https://forgejo.example REPOSITORY=owner/repo TAG="$tag" WORKFLOW=release.yml EXPECTED="$expected" TAG_CURL_LOG="$tag_curl_log" PATH="$tag_mock_bin:$PATH" sh -c "$tag_dispatch_script"
  )
}

assert_tag_points_at_head() {
  repo="$1"
  tag="$2"
  test "$(git -C "$repo" rev-parse "$tag^{}")" = "$(git -C "$repo" rev-parse HEAD)"
}

# A protected branch can retain the prepared release commit directly.
direct_repo="$test_dir/tag-direct"
direct_subject='chore(release): v2.0.0'
init_tag_repo "$direct_repo"
release_commit "$direct_repo" "$direct_subject"
run_tag_dispatch "$direct_repo" v2.0.0 "$direct_subject"
assert_tag_points_at_head "$direct_repo" v2.0.0

# A normal PR merge has the prepared release commit directly on the PR side.
merge_repo="$test_dir/tag-merge"
merge_subject='chore(release): v2.0.1'
init_tag_repo "$merge_repo"
git -C "$merge_repo" switch -qc release/v2.0.1
release_commit "$merge_repo" "$merge_subject"
git -C "$merge_repo" switch -q main
git -C "$merge_repo" merge --no-ff --no-edit release/v2.0.1
run_tag_dispatch "$merge_repo" v2.0.1 "$merge_subject"
assert_tag_points_at_head "$merge_repo" v2.0.1

# A no-force merge of main into the release branch puts the prepared commit
# below an integration merge, but it remains exclusive to the PR ancestry.
integration_repo="$test_dir/tag-integration"
integration_subject='chore(release): v2.0.2'
init_tag_repo "$integration_repo"
git -C "$integration_repo" switch -qc release/v2.0.2
release_commit "$integration_repo" "$integration_subject"
git -C "$integration_repo" switch -q main
printf '%s\n' main > "$integration_repo/main-only"
git -C "$integration_repo" add main-only
git -C "$integration_repo" commit -qm 'fix: main integration'
git -C "$integration_repo" switch -q release/v2.0.2
git -C "$integration_repo" merge --no-ff --no-edit main
git -C "$integration_repo" switch -q main
git -C "$integration_repo" merge --no-ff --no-edit release/v2.0.2
run_tag_dispatch "$integration_repo" v2.0.2 "$integration_subject"
assert_tag_points_at_head "$integration_repo" v2.0.2

# A CI-retrigger commit after that integration must not invalidate the tag.
retrigger_repo="$test_dir/tag-retrigger"
retrigger_subject='chore(release): v2.0.3'
init_tag_repo "$retrigger_repo"
git -C "$retrigger_repo" switch -qc release/v2.0.3
release_commit "$retrigger_repo" "$retrigger_subject"
git -C "$retrigger_repo" switch -q main
printf '%s\n' main > "$retrigger_repo/main-only"
git -C "$retrigger_repo" add main-only
git -C "$retrigger_repo" commit -qm 'fix: main integration'
git -C "$retrigger_repo" switch -q release/v2.0.3
git -C "$retrigger_repo" merge --no-ff --no-edit main
git -C "$retrigger_repo" commit --allow-empty -qm 'ci: retrigger required PR validation'
git -C "$retrigger_repo" switch -q main
git -C "$retrigger_repo" merge --no-ff --no-edit release/v2.0.3
run_tag_dispatch "$retrigger_repo" v2.0.3 "$retrigger_subject"
assert_tag_points_at_head "$retrigger_repo" v2.0.3

# An expected release subject in base history alone must never authorize a tag.
base_only_repo="$test_dir/tag-base-only"
base_only_subject='chore(release): v2.0.4'
init_tag_repo "$base_only_repo"
release_commit "$base_only_repo" "$base_only_subject"
git -C "$base_only_repo" switch -qc unrelated
printf '%s\n' unrelated > "$base_only_repo/unrelated"
git -C "$base_only_repo" add unrelated
git -C "$base_only_repo" commit -qm 'fix: unrelated change'
git -C "$base_only_repo" switch -q main
git -C "$base_only_repo" merge --no-ff --no-edit unrelated
run_tag_dispatch "$base_only_repo" v2.0.4 "$base_only_subject" && exit 1
! git -C "$base_only_repo" rev-parse --verify --quiet refs/tags/v2.0.4 >/dev/null

upload_script="$(ruby -ryaml -e 'doc = YAML.load_file(ARGV.fetch(0)); puts doc.fetch("runs").fetch("steps").fetch(0).fetch("run")' "$root/forgejo-upload-release-assets/action.yml")"
mock_bin="$test_dir/mock-bin"
mkdir "$mock_bin"
cat > "$mock_bin/curl" <<'EOF'
#!/bin/sh
set -eu

method=GET
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    -H|--form|-w) shift 2 ;;
    *) url="$1"; shift ;;
  esac
done

case "$method:$url" in
  GET:*'/assets?limit=100') printf '%s' "$MOCK_ASSETS" ;;
  GET:https://downloads.example/*) printf '%s' "$MOCK_EXISTING" > "$output" ;;
  POST:*) : > "$output"; printf 'POST\n' >> "$MOCK_CURL_LOG"; printf '201' ;;
  *) echo "unexpected curl request: $method $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$mock_bin/curl"

asset="$test_dir/foc.tar.gz"
printf 'release asset' > "$asset"
curl_log="$test_dir/curl.log"
run_upload_action() {
  TOKEN=dummy SERVER_URL=https://forgejo.example REPOSITORY=owner/repo RELEASE_ID=42 FILES="$asset" MOCK_CURL_LOG="$curl_log" PATH="$mock_bin:$PATH" sh -c "$upload_script"
}

: > "$curl_log"
MOCK_ASSETS='[]' MOCK_EXISTING='' run_upload_action
test "$(cat "$curl_log")" = 'POST'

: > "$curl_log"
MOCK_ASSETS='[{"name":"foc.tar.gz","browser_download_url":"https://downloads.example/foc.tar.gz"}]' MOCK_EXISTING='release asset' run_upload_action
test ! -s "$curl_log"

: > "$curl_log"
MOCK_ASSETS='[{"name":"foc.tar.gz","browser_download_url":"https://downloads.example/first"},{"name":"foc.tar.gz","browser_download_url":"https://downloads.example/second"}]' MOCK_EXISTING='' run_upload_action && exit 1
test ! -s "$curl_log"

: > "$curl_log"
MOCK_ASSETS='[{"name":"foc.tar.gz","browser_download_url":"https://downloads.example/foc.tar.gz"}]' MOCK_EXISTING='different asset' run_upload_action && exit 1
test ! -s "$curl_log"
