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
