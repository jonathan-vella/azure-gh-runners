package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/actions/scaleset"
)

type workerPolicy struct {
	Repository       string   `json:"repository"`
	Visibility       string   `json:"visibility"`
	AllowedEvents    []string `json:"allowedEvents"`
	AllowedRefs      []string `json:"allowedRefs"`
	AllowedWorkflows []string `json:"allowedWorkflows"`
}

// The returned bytes belong only in the ARM extension's protectedSettings.
// Never serialize them into a manifest, trace, public settings or CLI arguments.
func workerProtectedSettings(ctx context.Context, api scaleSetAPI, scaleSetID int, vmName string, policy workerPolicy) ([]byte, int, error) {
	if scaleSetID <= 0 || !regexp.MustCompile(`^vm-ghr-spike60-[a-f0-9]{25}-1$`).MatchString(vmName) ||
		policy.Repository != "jonathan-vella/ghr-smoke" || policy.Visibility != "public" ||
		len(policy.AllowedRefs) != 1 || policy.AllowedRefs[0] != "refs/heads/main" ||
		len(policy.AllowedEvents) != 1 || policy.AllowedEvents[0] != "workflow_dispatch" ||
		len(policy.AllowedWorkflows) == 0 || len(policy.AllowedWorkflows) > 2 {
		return nil, 0, errors.New("worker_handoff_contract_invalid")
	}
	workflowPattern := regexp.MustCompile(`^jonathan-vella/ghr-smoke/\.github/workflows/[A-Za-z0-9_-]+\.ya?ml@refs/heads/main$`)
	for _, workflow := range policy.AllowedWorkflows {
		if !workflowPattern.MatchString(workflow) {
			return nil, 0, errors.New("worker_workflow_allowlist_invalid")
		}
	}
	jit, err := api.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{
		Name: vmName, WorkFolder: "_work",
	}, scaleSetID)
	if err != nil {
		return nil, 0, errors.New("worker_jit_generation_failed")
	}
	if jit == nil || jit.Runner == nil || jit.Runner.ID <= 0 ||
		jit.Runner.Name != vmName || jit.Runner.RunnerScaleSetID != scaleSetID {
		return nil, 0, errors.New("worker_jit_response_invalid")
	}
	if len(jit.EncodedJITConfig) == 0 || len(jit.EncodedJITConfig) > 131072 ||
		!regexp.MustCompile(`^[A-Za-z0-9+/]+={0,2}$`).MatchString(jit.EncodedJITConfig) {
		return nil, jit.Runner.ID, errors.New("worker_jit_response_invalid")
	}
	policyJSON, err := json.Marshal(policy)
	if err != nil {
		return nil, jit.Runner.ID, errors.New("worker_policy_encoding_failed")
	}
	script := fmt.Sprintf(`#!/bin/bash
set -euo pipefail
umask 077
[[ $(id -u) == 0 ]]
case "$0" in
  /var/lib/waagent/custom-script/download/*/script.sh) rm -f -- "$0" ;;
  *) echo 'unexpected_cse_script_path' >&2; exit 1 ;;
esac
ready=false
for ((attempt=0; attempt<180; attempt++)); do
  if [[ -f /run/ghr-vmss/worker-ready && $(stat -c '%%u:%%a' /run/ghr-vmss/worker-ready) == 0:444 ]]; then
    ready=true
    break
  fi
  sleep 5
done
[[ $ready == true ]]
chmod -R go-rwx /var/lib/waagent
for file in /opt/ghr-vmss/run-one-job.sh /opt/runner-image/pre-job-policy.sh /opt/runner-image/pre-job-policy.py; do
  [[ $(stat -c '%%u:%%a' "$file") == 0:555 ]]
done
printf '%%s\n' %s | /usr/sbin/runuser --user runner -- /usr/bin/env -i \
  HOME=/home/runner PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  CONSUMER_POLICY_JSON=%s ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/runner-image/pre-job-policy.sh \
  AZURE_CORE_COLLECT_TELEMETRY=false AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no \
  AZURE_BICEP_USE_BINARY_FROM_PATH=true POWERSHELL_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  /usr/bin/timeout --signal=TERM --kill-after=10s 900s /bin/bash /opt/ghr-vmss/run-one-job.sh >/dev/null 2>&1
`, shellQuote(jit.EncodedJITConfig), shellQuote(string(policyJSON)))
	encodedScript := base64.StdEncoding.EncodeToString([]byte(script))
	if len(encodedScript) > 262144 {
		return nil, jit.Runner.ID, errors.New("worker_cse_script_too_large")
	}
	body, err := json.Marshal(struct {
		Script string `json:"script"`
	}{Script: encodedScript})
	if err != nil {
		return nil, jit.Runner.ID, errors.New("worker_protected_settings_encoding_failed")
	}
	return body, jit.Runner.ID, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
