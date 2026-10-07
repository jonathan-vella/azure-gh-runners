package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	spikeScope = "/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/resourceGroups/rg-ghrunners-spike-vmss-swc"
	armHost    = "https://management.azure.com"
)

type tokenSource func(context.Context, string) (string, error)

type armClient struct {
	http  *http.Client
	token tokenSource
}

func azureHTTPClient() *http.Client {
	return &http.Client{
		Timeout: 45 * time.Second, Transport: &http.Transport{Proxy: nil},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func managedIdentityToken(ctx context.Context, audience string) (string, error) {
	if audience != armHost+"/" && audience != "https://vault.azure.net" {
		return "", errors.New("identity_audience_invalid")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource="+url.QueryEscape(audience), nil)
	if err != nil {
		return "", errors.New("identity_request_invalid")
	}
	request.Header.Set("Metadata", "true")
	response, err := azureHTTPClient().Do(request)
	if err != nil {
		return "", errors.New("controller_identity_request_failed")
	}
	defer response.Body.Close()
	var token struct {
		AccessToken string `json:"access_token"`
		ExpiresOn   string `json:"expires_on"`
	}
	if response.StatusCode != http.StatusOK ||
		json.NewDecoder(io.LimitReader(response.Body, 65536)).Decode(&token) != nil {
		return "", errors.New("controller_identity_token_failed")
	}
	expiry, err := strconv.ParseInt(token.ExpiresOn, 10, 64)
	if err != nil || token.AccessToken == "" || time.Until(time.Unix(expiry, 0)) < time.Minute {
		return "", errors.New("controller_identity_token_invalid")
	}
	return token.AccessToken, nil
}

func (a *armClient) request(ctx context.Context, method, path string, body []byte) ([]byte, bool, error) {
	if !strings.HasPrefix(path, spikeScope+"/providers/") || strings.Contains(path, "..") ||
		strings.ContainsAny(path, "\r\n#%") ||
		(method != http.MethodGet && method != http.MethodPut && method != http.MethodDelete && method != http.MethodPost) {
		return nil, false, errors.New("arm_scope_or_method_invalid")
	}
	resourcePath := strings.SplitN(strings.TrimPrefix(path, spikeScope+"/providers/"), "?", 2)[0]
	deployment := regexp.MustCompile(`^Microsoft.Resources/deployments/dep-vm-ghr-spike60-[a-f0-9]{32}-1$`).MatchString(resourcePath)
	cancelDeployment := regexp.MustCompile(`^Microsoft.Resources/deployments/dep-vm-ghr-spike60-[a-f0-9]{32}-1/cancel$`).MatchString(resourcePath)
	workerResource := regexp.MustCompile(`^(Microsoft.Compute/virtualMachines/vm|Microsoft.Network/networkInterfaces/nic-vm|Microsoft.Compute/disks/disk-vm)-ghr-spike60-[a-f0-9]{25}-1(-os)?$`).MatchString(resourcePath)
	if (!deployment && !workerResource && !cancelDeployment) || method == http.MethodPut && !deployment ||
		method == http.MethodDelete && !workerResource || method == http.MethodPost && !cancelDeployment ||
		cancelDeployment && method != http.MethodPost {
		return nil, false, errors.New("arm_resource_operation_not_allowlisted")
	}

	token, err := a.token(ctx, armHost+"/")
	if err != nil {
		return nil, false, err
	}
	request, err := http.NewRequestWithContext(ctx, method, armHost+path, bytes.NewReader(body))
	if err != nil {
		return nil, false, errors.New("arm_request_invalid")
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := a.http.Do(request)
	if err != nil {
		return nil, false, errors.New("arm_transport_failed")
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound && method == http.MethodGet {
		return nil, true, nil
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		// Provider error bodies can contain protected settings. Never propagate them.
		return nil, false, errors.New("arm_operation_failed")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 16*1024*1024+1))
	if err != nil || len(data) > 16*1024*1024 {
		return nil, false, errors.New("arm_response_invalid")
	}
	return data, false, nil
}

func (a *armClient) settleWorkerDeployment(ctx context.Context, runID string) error {
	path := spikeScope + "/providers/Microsoft.Resources/deployments/dep-vm-ghr-spike60-" + runID + "-1"
	cancelRequested := false
	for {
		data, absent, err := a.request(ctx, http.MethodGet, path+"?api-version=2022-09-01", nil)
		if err != nil {
			return err
		}
		if absent {
			return errors.New("deployment_cleanup_absence_ambiguous")
		}
		var deployment struct {
			Properties struct {
				State string `json:"provisioningState"`
			} `json:"properties"`
		}
		if json.Unmarshal(data, &deployment) != nil {
			return errors.New("deployment_cleanup_status_invalid")
		}
		switch deployment.Properties.State {
		case "Succeeded", "Failed", "Canceled":
			return nil
		case "Accepted", "Running":
			if !cancelRequested {
				if _, _, err := a.request(ctx, http.MethodPost, path+"/cancel?api-version=2022-09-01", nil); err != nil {
					return err
				}
				cancelRequested = true
			}
		default:
			return errors.New("deployment_cleanup_status_invalid")
		}
		if pause(ctx, 5*time.Second) != nil {
			return errors.New("deployment_cleanup_terminal_unverified")
		}
	}
}

func privateAppKey(ctx context.Context, token tokenSource, client *http.Client, version string) (string, error) {
	if len(version) != 32 || strings.Trim(version, "0123456789abcdef") != "" {
		return "", errors.New("secret_version_invalid")
	}
	credential, err := token(ctx, "https://vault.azure.net")
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://kv-ghr-spike60-swc.vault.azure.net/secrets/github-app-private-key/"+version+"?api-version=7.4", nil)
	if err != nil {
		return "", errors.New("secret_request_invalid")
	}
	request.Header.Set("Authorization", "Bearer "+credential)
	response, err := client.Do(request)
	if err != nil {
		return "", errors.New("private_secret_request_failed")
	}
	defer response.Body.Close()
	var secret struct {
		Value string `json:"value"`
	}
	if response.StatusCode != http.StatusOK ||
		json.NewDecoder(io.LimitReader(response.Body, 32768)).Decode(&secret) != nil ||
		!strings.Contains(secret.Value, "PRIVATE KEY-----") || len(secret.Value) > 16384 {
		return "", errors.New("private_secret_read_failed")
	}
	return secret.Value, nil
}

type ownedWorker struct {
	Name                string `json:"name"`
	VMID                string `json:"vmId"`
	NICID               string `json:"nicId"`
	DiskID              string `json:"osDiskId"`
	RunnerID            int    `json:"runnerId"`
	JobRequest          int64  `json:"jobRequestId"`
	JobComplete         bool   `json:"jobComplete"`
	Phase               string `json:"phase"`
	DeploymentAttempted bool   `json:"deploymentAttempted"`
}

func expectedWorker(runID string, index int) ownedWorker {
	prefix := runID
	if len(prefix) > 25 {
		prefix = prefix[:25]
	}
	name := "vm-ghr-spike60-" + prefix + "-" + strconv.Itoa(index)
	return ownedWorker{
		Name: name, VMID: spikeScope + "/providers/Microsoft.Compute/virtualMachines/" + name,
		NICID:  spikeScope + "/providers/Microsoft.Network/networkInterfaces/nic-" + name,
		DiskID: spikeScope + "/providers/Microsoft.Compute/disks/disk-" + name + "-os",
	}
}

func (a *armClient) removeWorker(ctx context.Context, worker ownedWorker, runID, head string) error {
	expected := expectedWorker(runID, 1)
	if worker.Name != expected.Name || worker.VMID != expected.VMID || worker.NICID != expected.NICID || worker.DiskID != expected.DiskID {
		return errors.New("worker_cleanup_ids_invalid")
	}
	for _, resource := range []struct{ id, version string }{
		{worker.VMID, "2024-07-01"}, {worker.NICID, "2024-05-01"}, {worker.DiskID, "2024-03-02"},
	} {
		path := resource.id + "?api-version=" + resource.version
		data, absent, err := a.request(ctx, http.MethodGet, path, nil)
		if err != nil {
			return err
		}
		if absent {
			continue
		}
		var metadata struct {
			ID   string            `json:"id"`
			Tags map[string]string `json:"tags"`
		}
		if json.Unmarshal(data, &metadata) != nil || !strings.EqualFold(metadata.ID, resource.id) ||
			metadata.Tags["spike-id"] != "60" || metadata.Tags["spike-run-id"] != runID || metadata.Tags["spike-head"] != head {
			return errors.New("worker_cleanup_ownership_failed")
		}
		if _, _, err = a.request(ctx, http.MethodDelete, path, nil); err != nil {
			return err
		}
		for {
			if err := pause(ctx, 5*time.Second); err != nil {
				return errors.New("worker_cleanup_deadline_exhausted")
			}
			_, absent, err = a.request(ctx, http.MethodGet, path, nil)
			if err != nil {
				return err
			}
			if absent {
				break
			}
		}
	}
	return nil
}

func pause(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
