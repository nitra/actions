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
