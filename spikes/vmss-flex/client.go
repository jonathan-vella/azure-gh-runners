package main

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

const (
	repositoryURL = "https://github.com/jonathan-vella/ghr-smoke"
	appClientID   = "Iv23liLOmKrlxX0rFd2z"
)

// Compile against the pinned API, not the unrelated repository REST JIT API.
type scaleSetAPI interface {
	GetRunnerScaleSet(context.Context, int, string) (*scaleset.RunnerScaleSet, error)
	CreateRunnerScaleSet(context.Context, *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error)
	DeleteRunnerScaleSet(context.Context, int) error
	GenerateJitRunnerConfig(context.Context, *scaleset.RunnerScaleSetJitRunnerSetting, int) (*scaleset.RunnerScaleSetJitRunnerConfig, error)
}

var _ scaleSetAPI = (*scaleset.Client)(nil)
var _ listener.Client = (*scaleset.MessageSessionClient)(nil)

func newClient(installationID int64, privateKey string) (*scaleset.Client, error) {
	client, err := scaleset.NewClientWithGitHubApp(scaleset.ClientWithGitHubAppConfig{
		GitHubConfigURL: repositoryURL,
		GitHubAppAuth: scaleset.GitHubAppAuth{
			ClientID: appClientID, InstallationID: installationID, PrivateKey: privateKey,
		},
		SystemInfo: scaleset.SystemInfo{System: "azure-gh-runners-spike60", Subsystem: "bounded-vmss-spike"},
	}, scaleset.WithLogger(slog.New(slog.DiscardHandler)),
		scaleset.WithTimeout(20*time.Second), scaleset.WithRetryMax(-1))
	if err != nil {
		return nil, errors.New("client_configuration_failed")
	}
	return client, nil
}

// This probe never listens for jobs or creates a JIT credential.
func probe(ctx context.Context, api scaleSetAPI, name string) (id int, resultErr error) {
	existing, err := api.GetRunnerScaleSet(ctx, 1, name)
	if err != nil {
		return 0, errors.New("scale_set_lookup_failed")
	}
	if existing != nil {
		return 0, errors.New("scale_set_name_already_exists")
	}

	// A failed create can still have reached GitHub. Resolve by the unique owned name
	// using a fresh cleanup context, even after the experiment context expires.
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if id == 0 {
			owned, lookupErr := api.GetRunnerScaleSet(cleanupCtx, 1, name)
			if lookupErr != nil {
				resultErr = errors.New("scale_set_cleanup_lookup_failed")
				return
			}
			if owned == nil {
				return
			}
			id = owned.ID
		}
		if id <= 0 || api.DeleteRunnerScaleSet(cleanupCtx, id) != nil {
			resultErr = errors.New("scale_set_cleanup_delete_failed")
			return
		}
		remaining, lookupErr := api.GetRunnerScaleSet(cleanupCtx, 1, name)
		if lookupErr != nil || remaining != nil {
			resultErr = errors.New("scale_set_cleanup_absence_unverified")
		}
	}()

	created, err := api.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{
		Name: name, RunnerGroupID: 1,
		Labels:        []scaleset.Label{{Name: name, Type: "System"}},
		RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true},
	})
	if err != nil {
		return 0, errors.New("scale_set_create_failed")
	}
	if created == nil || created.ID <= 0 {
		return 0, errors.New("scale_set_create_invalid_response")
	}
	id = created.ID
	readback, err := api.GetRunnerScaleSet(ctx, 1, name)
	if err != nil || readback == nil || readback.ID != id || readback.Name != name ||
		len(readback.Labels) != 1 || readback.Labels[0].Name != name {
		return id, errors.New("scale_set_custom_label_readback_failed")
	}
	return id, nil
}
