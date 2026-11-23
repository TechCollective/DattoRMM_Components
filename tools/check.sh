#!/usr/bin/env bash
# Runs every CI check that can run on a Linux machine, before you push:
#
#   tools/check.sh              everything below
#   tools/check.sh --no-docker  the Python checks only
#
# In a throwaway container (needs Docker): the lint job with the shellcheck
# and PSScriptAnalyzer versions CI pins, and the Linux harness self-test,
# which belongs on a disposable machine. The Windows harness, its self-test
# and the per-component tests run only in CI.
#
# Keep in step with the workflows in .github/workflows/: they are the source
# of truth for what CI runs.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

failed=()
step() {
    local name="$1"; shift
    echo "=== $name"
    if "$@"; then echo "--- ok: $name"; else echo "--- FAILED: $name"; failed+=("$name"); fi
}

dist=$(mktemp -d); trap 'rm -rf "$dist"' EXIT
step "Packer tests"        python3 -m unittest discover -s tools -p 'test_*.py'
step "Discovery tests"     python3 -m unittest discover -s tools/test-harness -p 'test_*.py'
step "Audit committed .cpt" python3 tools/cpt.py audit
step "Build every component" python3 tools/cpt.py pack-all --out-dir "$dist"
step "Shared blocks match" python3 tools/check-shared-blocks.py
step "Addresses and domains" python3 tools/check-public-safety.py
if gitleaks git --help >/dev/null 2>&1; then
    step "Secret scan (this branch)" gitleaks git --no-banner --redact --log-opts=origin/main..HEAD .
else
    echo "=== Skipped: secret scan (needs gitleaks 8.19 or later; CI runs it)"
fi

# shellcheck disable=SC2317  # called through step, which shellcheck cannot follow
in_container() {
    # In a worktree, .git is a file naming the main repo's .git by absolute
    # path, so mount that too, at the same path.
    local common mounts=(-v "$PWD":/repo:ro)
    if [ -f .git ]; then
        common=$(cd "$(git rev-parse --git-common-dir)" && pwd) || return 1
        mounts+=(-v "$common":"$common":ro)
    fi
    # Same pins as .github/workflows/lint-components.yml.
    docker run --rm "${mounts[@]}" -w /repo mcr.microsoft.com/powershell:7.4-ubuntu-22.04 bash -c '
        set -e
        apt-get update -qq >/dev/null && apt-get install -y -qq git jq sudo curl xz-utils >/dev/null 2>&1
        git config --global --add safe.directory /repo
        curl -fsSLo /tmp/sc.tar.xz https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz
        echo "6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87  /tmp/sc.tar.xz" | sha256sum -c - >/dev/null
        tar -xJf /tmp/sc.tar.xz -C /tmp && export PATH="/tmp/shellcheck-v0.10.0:$PATH"
        pwsh -NoProfile -c "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module PSScriptAnalyzer -RequiredVersion 1.23.0 -Scope CurrentUser" >/dev/null
        rc=0
        echo "=== Lint components"; pwsh -NoProfile tools/lint-components.ps1 || rc=1
        echo "=== Harness self-test (linux)"; pwsh -NoProfile tools/test-harness/self-test/Invoke-HarnessSelfTest.ps1 || rc=1
        exit $rc'
}
if [ "${1:-}" = --no-docker ]; then
    echo "=== Skipped: lint and the Linux harness self-test (--no-docker)"
elif ! command -v docker >/dev/null; then
    echo "=== Skipped: lint and the Linux harness self-test (Docker is not installed)"
    failed+=("lint and self-test not run")
else
    step "Lint and Linux harness self-test (container)" in_container
fi

echo
echo "Not run here: the Windows harness self-test and the component tests. They run only in CI."
if [ ${#failed[@]} -eq 0 ]; then echo "All checks passed."; exit 0; fi
printf 'FAILED: %s\n' "${failed[@]}"
exit 1
