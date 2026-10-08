package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func workerParameterFixture() controllerConfig {
	c := controllerConfig{RunID: strings.Repeat("a", 32), Head: strings.Repeat("b", 40)}
	c.WorkerParameters = make(map[string]json.RawMessage)
	for key, value := range map[string]any{
		"runId": c.RunID, "head": c.Head, "workerIndex": 1,
		"canonicalUbuntuVersion": "24.04.202609260",
		"adminSshPublicKey":      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfakefixture",
		"flexScaleSetResourceId": spikeScope + "/providers/Microsoft.Compute/virtualMachineScaleSets/spike60",
		"workerSubnetResourceId": spikeScope + "/providers/Microsoft.Network/virtualNetworks/spike60/subnets/worker",
		"bootstrapCustomData":    base64.StdEncoding.EncodeToString([]byte("#cloud-config")),
	} {
		c.WorkerParameters[key], _ = json.Marshal(value)
	}
	return c
}

func TestWorkerParameterBoundary(t *testing.T) {
	if workerParameterFixture().validateWorkerParameters() != nil {
		t.Fatal("valid fixed worker parameters rejected")
	}
	for key, value := range map[string]any{
		"runId": strings.Repeat("c", 32), "head": strings.Repeat("c", 40),
		"workerIndex": 2, "canonicalUbuntuVersion": "latest",
		"runOrdinal": 2,
		"flexScaleSetResourceId": "/subscriptions/foreign/resourceGroups/production",
		"workerSubnetResourceId": spikeScope + "/providers/Microsoft.Network/virtualNetworks/../other",
		"bootstrapCustomData":    "invalid!",
		"jitProtectedScript":     "not-a-public-parameter",
	} {
		t.Run(key, func(t *testing.T) {
			c := workerParameterFixture()
			c.WorkerParameters[key], _ = json.Marshal(value)
			if c.validateWorkerParameters() == nil {
				t.Fatal("foreign/additional/slot-two parameters accepted")
			}
		})
	}
}

func TestGeneratedPowerShellWorkerParameters(t *testing.T) {
	path := os.Getenv("GHR_SPIKE_TEST_WORKER_PARAMETERS")
	if path == "" {
		t.Skip("generated PowerShell fixture is supplied by Test-Client.ps1")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("generated PowerShell worker parameter fixture unavailable")
	}
	var parameters map[string]json.RawMessage
	if json.Unmarshal(data, &parameters) != nil {
		t.Fatal("generated PowerShell worker parameter fixture is invalid JSON")
	}
	var runID, head string
	if json.Unmarshal(parameters["runId"], &runID) != nil ||
		json.Unmarshal(parameters["head"], &head) != nil {
		t.Fatal("generated PowerShell worker identity is invalid")
	}
	config := controllerConfig{RunID: runID, Head: head, WorkerParameters: parameters}
	if err := config.validateWorkerParameters(); err != nil {
		t.Fatalf("Go validator rejected generated PowerShell worker parameters: %v", err)
	}
}
