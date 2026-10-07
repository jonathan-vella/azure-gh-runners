package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"runtime"
	"syscall"
	"time"
)

type probeEvidence struct {
	ScaleSetID int    `json:"scaleSetId"`
	Result     string `json:"result"`
}

func run() (result probeEvidence) {
	flags := flag.NewFlagSet("vmss-spike-probe", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	execute := flags.Bool("execute-on-private-controller", false, "requires separate coordinator execution direction")
	runID := flags.String("run-id", "", "32 lowercase hexadecimal characters from the durable run manifest")
	installationID := flags.Int64("installation-id", 0, "existing selected-repository installation ID")
	deadline := flags.String("work-deadline", "", "UTC work deadline from the durable run manifest")
	controllerConfigPath := flags.String("controller-config", "", "fixed private-controller configuration path")
	cleanupOnly := flags.Bool("cleanup-on-private-controller", false, "recover only the captured owned resources")
	if flags.Parse(os.Args[1:]) != nil || flags.NArg() != 0 {
		return probeEvidence{Result: "invalid_flags"}
	}
	if *controllerConfigPath != "" {
		if (!*execute && !*cleanupOnly) || *execute && *cleanupOnly ||
			*controllerConfigPath != "/opt/ghr-vmss/controller.json" ||
			runtime.GOOS != "linux" || os.Geteuid() != 1002 || !onAuthorizedController() {
			return probeEvidence{Result: "controller_execution_gate_failed"}
		}
		var config controllerConfig
		if readStrictJSON(*controllerConfigPath, &config) != nil {
			return probeEvidence{Result: "controller_configuration_invalid"}
		}
		checkTime := time.Now()
		if *cleanupOnly {
			checkTime = config.StartedUTC
		}
		if config.validate(checkTime) != nil {
			return probeEvidence{Result: "controller_configuration_invalid"}
		}
		lock, err := os.OpenFile("/var/lib/ghr-vmss/journal.lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
		if err != nil {
			return probeEvidence{Result: "controller_lock_failed"}
		}
		defer lock.Close()
		if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
			return probeEvidence{Result: "controller_already_running"}
		}
		if !*cleanupOnly {
			result = probeEvidence{Result: "controller_panicked"}
			defer func() {
				if writeJSONFile("/var/lib/ghr-vmss/outcome.json", result) != nil {
					result = probeEvidence{Result: "controller_outcome_write_failed"}
				}
			}()
		}
		signalCtx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stopSignals()
		stop := config.WorkDeadlineUTC
		if *cleanupOnly {
			stop = time.Now().Add(5 * time.Minute)
		}
		if config.HardDeadlineUTC.Before(stop) {
			stop = config.HardDeadlineUTC
		}
		ctx, cancel := context.WithDeadline(signalCtx, stop)
		defer cancel()
		azure := azureHTTPClient()
		key, err := privateAppKey(ctx, managedIdentityToken, azure, config.SecretVersion)
		if err != nil {
			return probeEvidence{Result: err.Error()}
		}
		client, err := newClient(config.InstallationID, key)
		if err != nil {
			return probeEvidence{Result: "client_configuration_failed"}
		}
		arm := &armClient{http: azure, token: managedIdentityToken}
		if *cleanupOnly {
			if err := controllerCleanup(ctx, config, client, arm); err != nil {
				return probeEvidence{Result: err.Error()}
			}
			return probeEvidence{Result: "controller_cleanup_absence_verified"}
		}
		err = runController(ctx, config, client, arm)
		if err != nil {
			return probeEvidence{Result: err.Error()}
		}
		return probeEvidence{Result: "one_job_lifecycle_completed_acceptance_unverified"}
	}
	if !*execute || runtime.GOOS != "linux" || os.Geteuid() == 0 ||
		!regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(*runID) || *installationID <= 0 {
		return probeEvidence{Result: "controller_execution_gate_failed"}
	}
	stop, err := time.Parse(time.RFC3339, *deadline)
	if err != nil || time.Until(stop) < 2*time.Minute || time.Until(stop) > 3*time.Hour {
		return probeEvidence{Result: "work_deadline_invalid"}
	}
	if !onAuthorizedController() {
		return probeEvidence{Result: "controller_metadata_gate_failed"}
	}
	key, err := readControllerKey()
	if err != nil {
		return probeEvidence{Result: "controller_key_delivery_invalid"}
	}
	client, err := newClient(*installationID, string(key))
	clear(key)
	if err != nil {
		return probeEvidence{Result: "client_configuration_failed"}
	}
	// No key, token, request body, or provider error is emitted.
	experimentStop := time.Now().Add(time.Minute)
	if cleanupCutoff := stop.Add(-time.Minute); cleanupCutoff.Before(experimentStop) {
		experimentStop = cleanupCutoff
	}
	signalCtx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	ctx, cancel := context.WithDeadline(signalCtx, experimentStop)
	defer cancel()
	id, err := probe(ctx, client, "ghr-smoke-vmss-spike-"+*runID)
	if err != nil {
		return probeEvidence{ScaleSetID: id, Result: err.Error()}
	}
	return probeEvidence{ScaleSetID: id, Result: "repository_scale_set_probe_passed"}
}

func onAuthorizedController() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01", nil)
	if err != nil {
		return false
	}
	request.Header.Set("Metadata", "true")
	client := &http.Client{
		Timeout:   5 * time.Second,
		Transport: &http.Transport{Proxy: nil},
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	var metadata struct {
		SubscriptionID    string `json:"subscriptionId"`
		ResourceGroupName string `json:"resourceGroupName"`
		Location          string `json:"location"`
		Name              string `json:"name"`
		VMSize            string `json:"vmSize"`
	}
	if response.StatusCode != http.StatusOK ||
		json.NewDecoder(io.LimitReader(response.Body, 65536)).Decode(&metadata) != nil {
		return false
	}
	return metadata.SubscriptionID == "b47d2942-f5ad-4d3c-b28e-c23e4f83d97e" &&
		metadata.ResourceGroupName == "rg-ghrunners-spike-vmss-swc" &&
		metadata.Location == "swedencentral" && metadata.Name == "vm-ghr-spike60-controller" &&
		metadata.VMSize == "Standard_B2s"
}

func readControllerKey() ([]byte, error) {
	const path = "/run/ghr-vmss/app.pem"
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0400 ||
		info.Size() < 1 || info.Size() > 16384 {
		return nil, errors.New("invalid_key_file")
	}
	return os.ReadFile(path)
}

func main() {
	result := probeEvidence{Result: "probe_panicked"}
	func() {
		defer func() {
			if recover() != nil {
				result = probeEvidence{Result: "probe_panicked"}
			}
		}()
		result = run()
	}()
	encoded, err := json.Marshal(result)
	if err != nil {
		fmt.Fprintln(os.Stderr, `{"result":"evidence_encoding_failed"}`)
		os.Exit(1)
	}
	fmt.Println(string(encoded))
	if result.Result != "repository_scale_set_probe_passed" &&
		result.Result != "controller_cleanup_absence_verified" &&
		result.Result != "one_job_lifecycle_completed_acceptance_unverified" {
		os.Exit(1)
	}
}
