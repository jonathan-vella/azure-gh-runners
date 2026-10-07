package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/actions/scaleset"
)

type workerFake struct {
	fakeAPI
	fail bool
	jit  string
}

func (f *workerFake) GenerateJitRunnerConfig(_ context.Context, settings *scaleset.RunnerScaleSetJitRunnerSetting, id int) (*scaleset.RunnerScaleSetJitRunnerConfig, error) {
	if f.fail {
		return nil, errors.New("provider-secret-jit-token")
	}
	return &scaleset.RunnerScaleSetJitRunnerConfig{
		Runner:           &scaleset.RunnerReference{ID: 91, Name: settings.Name, RunnerScaleSetID: id},
		EncodedJITConfig: f.jit,
	}, nil
}

func TestWorkerProtectedHandoff(t *testing.T) {
	policy := workerPolicy{
		Repository: "jonathan-vella/ghr-smoke", Visibility: "public",
		AllowedEvents: []string{"workflow_dispatch"}, AllowedRefs: []string{"refs/heads/main"},
		AllowedWorkflows: []string{"jonathan-vella/ghr-smoke/.github/workflows/smoke.yml@refs/heads/main"},
		WorkflowSHA:      strings.Repeat("b", 40),
	}
	api := &workerFake{jit: "ZmFrZS1qaXQ="}
	name := "vm-ghr-spike60-" + strings.Repeat("a", 25) + "-1"
	body, id, err := workerProtectedSettings(context.Background(), api, 42, name, policy)
	if err != nil || id != 91 {
		t.Fatal("valid handoff failed")
	}
	var protected map[string]string
	if json.Unmarshal(body, &protected) != nil || len(protected) != 1 || protected["script"] == "" {
		t.Fatal("handoff is not a protected inline script")
	}
	script, err := base64.StdEncoding.DecodeString(protected["script"])
	if err != nil || !strings.Contains(string(script), "runuser --user runner -- /usr/bin/env -i") ||
		!strings.Contains(string(script), "900s") || strings.Contains(string(script), "set -x") ||
		strings.Contains(string(script), "GH_APP") || strings.Contains(string(body), api.jit) {
		t.Fatal("handoff did not isolate JIT delivery/worker env")
	}
	if !strings.Contains(string(script), "GHR_SPIKE_WORKFLOW_SHA='"+policy.WorkflowSHA+"'") ||
		!strings.Contains(string(script), "ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ghr-vmss/pre-job-spike.sh") {
		t.Fatal("reviewed commit guard not wired into worker pre-job hook")
	}
	var shared map[string]any
	sharedJSON, _ := json.Marshal(map[string]any{
		"repository": policy.Repository, "visibility": policy.Visibility, "allowedEvents": policy.AllowedEvents,
		"allowedRefs": policy.AllowedRefs, "allowedWorkflows": policy.AllowedWorkflows,
	})
	if json.Unmarshal(sharedJSON, &shared) != nil || strings.Contains(string(sharedJSON), "workflowSha") ||
		!strings.Contains(string(script), shellQuote(string(sharedJSON))) {
		t.Fatal("spike commit pin leaked into unchanged shared policy schema")
	}
	policy.WorkflowSHA = ""
	if _, _, err := workerProtectedSettings(context.Background(), api, 42, name, policy); err == nil {
		t.Fatal("missing reviewed workflow commit allowed")
	}
	policy.WorkflowSHA = strings.Repeat("b", 40)
	api.fail = true
	if _, _, err = workerProtectedSettings(context.Background(), api, 42, name, policy); err == nil ||
		err.Error() != "worker_jit_generation_failed" {
		t.Fatal("provider error was not sanitized")
	}
	api.fail = false
	api.jit = "'; injected"
	if _, id, err = workerProtectedSettings(context.Background(), api, 42, name, policy); err == nil || id != 91 {
		t.Fatal("unsafe JIT accepted or captured owned runner ID lost")
	}
	policy.AllowedEvents = []string{"pull_request"}
	if _, _, err = workerProtectedSettings(context.Background(), api, 42, name, policy); err == nil ||
		err.Error() != "worker_handoff_contract_invalid" {
		t.Fatal("public policy widened")
	}
}
