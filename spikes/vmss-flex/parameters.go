package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"regexp"
)

func (c controllerConfig) validateWorkerParameters() error {
	allowed := []string{"runId", "head", "workerIndex", "canonicalUbuntuVersion", "adminSshPublicKey",
		"flexScaleSetResourceId", "workerSubnetResourceId", "bootstrapCustomData"}
	if len(c.WorkerParameters) != len(allowed) {
		return errors.New("worker_parameters_invalid")
	}
	for _, name := range allowed {
		if _, present := c.WorkerParameters[name]; !present {
			return errors.New("worker_parameters_invalid")
		}
	}
	var index int
	var runID, head, version, key, flex, subnet, data string
	fields := map[string]*string{"runId": &runID, "head": &head, "canonicalUbuntuVersion": &version,
		"adminSshPublicKey": &key, "flexScaleSetResourceId": &flex, "workerSubnetResourceId": &subnet,
		"bootstrapCustomData": &data}
	for name, target := range fields {
		if json.Unmarshal(c.WorkerParameters[name], target) != nil {
			return errors.New("worker_parameters_invalid")
		}
	}
	if json.Unmarshal(c.WorkerParameters["workerIndex"], &index) != nil || index != 1 ||
		runID != c.RunID || head != c.Head ||
		!regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(version) ||
		!regexp.MustCompile(`^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,2}$`).MatchString(key) || len(key) > 4096 ||
		!regexp.MustCompile(`^`+regexp.QuoteMeta(spikeScope)+`/providers/Microsoft.Compute/virtualMachineScaleSets/[A-Za-z0-9_-]+$`).MatchString(flex) ||
		!regexp.MustCompile(`^`+regexp.QuoteMeta(spikeScope)+`/providers/Microsoft.Network/virtualNetworks/[A-Za-z0-9_-]+/subnets/[A-Za-z0-9_-]+$`).MatchString(subnet) {
		return errors.New("worker_parameters_scope_invalid")
	}
	decoded, err := base64.StdEncoding.DecodeString(data)
	if err != nil || len(decoded) == 0 || len(decoded) > 64000 {
		return errors.New("worker_bootstrap_data_invalid")
	}
	return nil
}
