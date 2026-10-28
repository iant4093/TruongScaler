#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tools="${RUNNER_TEMP:-$PWD/build}/workflow-tools"
mkdir -p "$tools"
fetch() {
  local url="$1" checksum="$2" output="$3"
  curl --fail --location --silent --show-error --retry 3 "$url" -o "$output"
  printf '%s  %s\n' "$checksum" "$output" | sha256sum --check
}
fetch https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz \
  8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 "$tools/actionlint.tar.gz"
tar -xzf "$tools/actionlint.tar.gz" -C "$tools" actionlint
"$tools/actionlint" -color -config-file .github/actionlint.yaml
shellcheck scripts/*.sh
python3 -m venv "$tools/venv"
"$tools/venv/bin/pip" --disable-pip-version-check install --quiet zizmor==1.31.1
"$tools/venv/bin/zizmor" --offline .github/workflows
fetch https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz \
  551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb "$tools/gitleaks.tar.gz"
tar -xzf "$tools/gitleaks.tar.gz" -C "$tools" gitleaks
"$tools/gitleaks" git --redact --no-banner --log-opts=--all .
