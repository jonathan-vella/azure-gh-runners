package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

type controllerConfig struct {
	RunID              string                     `json:"runId"`
	Head               string                     `json:"head"`
	StartedUTC         time.Time                  `json:"startedUtc"`
	WorkDeadlineUTC    time.Time                  `json:"workDeadlineUtc"`
	HardDeadlineUTC    time.Time                  `json:"hardDeadlineUtc"`
	FoundationAttempts int                        `json:"foundationAttempts"`
	InstallationID     int64                      `json:"installationId"`
	SecretVersion      string                     `json:"secretVersion"`
	TemplateSHA256     string                     `json:"templateSha256"`
	WorkerParameters   map[string]json.RawMessage `json:"workerParameters"`
	Policy             workerPolicy               `json:"policy"`
}

type controllerJournal struct {
	RunID             string       `json:"runId"`
	Head              string       `json:"head"`
	StartedUTC        time.Time    `json:"startedUtc"`
	Attempts          int          `json:"attempts"`
	ScaleSetID        int          `json:"scaleSetId"`
	ScaleSetAttempted bool         `json:"scaleSetAttempted"`
	Worker            *ownedWorker `json:"worker"`
}

func (c controllerConfig) validate(now time.Time) error {
	if !regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(c.RunID) ||
		!regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(c.Head) ||
		!regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(c.TemplateSHA256) ||
		!regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(c.SecretVersion) ||
		c.InstallationID <= 0 || c.FoundationAttempts != 1 ||
		c.StartedUTC.IsZero() || now.Before(c.StartedUTC) ||
		!c.WorkDeadlineUTC.Equal(c.StartedUTC.Add(3*time.Hour)) ||
		!c.HardDeadlineUTC.Equal(c.StartedUTC.Add(4*time.Hour)) ||
		!now.Add(50*time.Minute).Before(c.WorkDeadlineUTC) {
		return errors.New("controller_original_envelope_invalid")
	}
	return nil
}

func controllerCleanup(ctx context.Context, config controllerConfig, api controllerAPI, arm *armClient) error {
	var state controllerJournal
	if readStrictJSON("/var/lib/ghr-vmss/journal.json", &state) != nil ||
		state.RunID != config.RunID || state.Head != config.Head ||
		!state.StartedUTC.Equal(config.StartedUTC) || state.Attempts < 1 || state.Attempts > 2 ||
		state.Attempts == 2 && state.Worker == nil {
		return errors.New("controller_cleanup_state_invalid")
	}
	s := &spikeScaler{api: api, arm: arm, config: config, state: state,
		path: "/var/lib/ghr-vmss/journal.json"}
	return s.cleanup(ctx)
}

func readStrictJSON(path string, value any) error {
	file, err := os.Open(path)
	if err != nil {
		return errors.New("controller_state_read_failed")
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 1024*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(value) != nil || decoder.Decode(new(any)) != io.EOF {
		return errors.New("controller_state_invalid")
	}
	return nil
}

func writeJournal(path string, state controllerJournal) error {
	return writeJSONFile(path, state)
}

func writeJSONFile(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return errors.New("controller_state_encoding_failed")
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".journal-*")
	if err != nil {
		return errors.New("controller_state_write_failed")
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if file.Chmod(0600) != nil {
		return errors.New("controller_state_permissions_failed")
	}
	if _, err = file.Write(data); err != nil || file.Sync() != nil || file.Close() != nil {
		return errors.New("controller_state_write_failed")
	}
	if os.Rename(file.Name(), path) != nil {
		return errors.New("controller_state_commit_failed")
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return errors.New("controller_state_commit_failed")
	}
	defer directory.Close()
	if directory.Sync() != nil {
		return errors.New("controller_state_commit_failed")
	}
	return nil
}

type controllerAPI interface {
	scaleSetAPI
	GetRunnerByName(context.Context, string) (*scaleset.RunnerReference, error)
	RemoveRunner(context.Context, int64) error
}

type spikeScaler struct {
	mu       sync.Mutex
	wg       sync.WaitGroup
	api      controllerAPI
	arm      *armClient
	config   controllerConfig
	state    controllerJournal
	path     string
	template json.RawMessage
	workCtx  context.Context
	finished chan error
	once     sync.Once
}

var _ listener.Scaler = (*spikeScaler)(nil)

func (s *spikeScaler) finish(err error) {
	s.once.Do(func() { s.finished <- err })
}

func (s *spikeScaler) HandleDesiredRunnerCount(_ context.Context, count int) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workCtx.Err() != nil {
		return 0, errors.New("controller_work_cancelled")
	}
	if count < 0 {
		return 0, errors.New("assigned_job_count_invalid")
	}
	if s.state.Worker != nil {
		return 1, nil
	}
	if count == 0 {
		return 0, nil
	}
	// One foundation consumed attempt 1. Reserve the only worker invocation
	// before JIT generation/ARM; failures never refund this reservation.
	if s.state.Attempts != 1 || s.config.validate(time.Now()) != nil {
		return 0, errors.New("worker_attempt_or_time_exhausted")
	}
	worker := expectedWorker(s.config.RunID, 1)
	worker.Phase = "reserved"
	s.state.Worker = &worker
	s.state.Attempts = 2
	if err := writeJournal(s.path, s.state); err != nil {
		return 0, err
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		if err := s.provision(); err != nil {
			s.finish(err)
		}
	}()
	return 1, nil
}

func (s *spikeScaler) correlate(runnerID int, name string, requestID int64) error {
	worker := s.state.Worker
	if worker == nil || runnerID <= 0 || runnerID != worker.RunnerID ||
		name != worker.Name || requestID <= 0 {
		return errors.New("job_runner_correlation_failed")
	}
	if worker.JobRequest != 0 && worker.JobRequest != requestID {
		return errors.New("worker_second_job_rejected")
	}
	worker.JobRequest = requestID
	return nil
}

func (s *spikeScaler) HandleJobStarted(_ context.Context, job *scaleset.JobStarted) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if job == nil {
		return errors.New("job_started_invalid")
	}
	if err := s.correlate(job.RunnerID, job.RunnerName, job.RunnerRequestID); err != nil {
		return err
	}
	s.state.Worker.Phase = "job-started"
	return writeJournal(s.path, s.state)
}

func (s *spikeScaler) HandleJobCompleted(_ context.Context, job *scaleset.JobCompleted) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if job == nil {
		return errors.New("job_completed_invalid")
	}
	if err := s.correlate(job.RunnerID, job.RunnerName, job.RunnerRequestID); err != nil {
		return err
	}
	s.state.Worker.JobComplete = true
	s.state.Worker.Phase = "job-completed"
	if err := writeJournal(s.path, s.state); err != nil {
		return err
	}
	// Completion alone is lifecycle evidence, not proof of policy/NAT/MI tests.
	s.finish(nil)
	return nil
}

func (s *spikeScaler) provision() error {
	ctx, cancel := context.WithTimeout(s.workCtx, 40*time.Minute)
	defer cancel()
	if err := s.config.validateWorkerParameters(); err != nil {
		return err
	}
	protected, runnerID, err := workerProtectedSettings(ctx, s.api, s.state.ScaleSetID,
		expectedWorker(s.config.RunID, 1).Name, s.config.Policy)
	defer clear(protected)
	s.mu.Lock()
	s.state.Worker.RunnerID = runnerID
	s.state.Worker.Phase = "jit-created"
	persistErr := writeJournal(s.path, s.state)
	s.mu.Unlock()
	if persistErr != nil {
		return persistErr
	}
	if err != nil {
		return err
	}
	var settings struct {
		Script string `json:"script"`
	}
	if json.Unmarshal(protected, &settings) != nil {
		return errors.New("worker_protected_settings_invalid")
	}
	parameters := make(map[string]any, len(s.config.WorkerParameters)+1)
	for name, value := range s.config.WorkerParameters {
		parameters[name] = map[string]any{"value": value}
	}
	parameters["jitProtectedScript"] = map[string]any{"value": settings.Script}
	payload, err := json.Marshal(map[string]any{"properties": map[string]any{
		"mode": "Incremental", "template": s.template, "parameters": parameters,
	}})
	if err != nil {
		return errors.New("worker_deployment_encoding_failed")
	}
	defer clear(payload)
	path := spikeScope + "/providers/Microsoft.Resources/deployments/dep-vm-ghr-spike60-" +
		s.config.RunID + "-1?api-version=2022-09-01"
	s.mu.Lock()
	s.state.Worker.DeploymentAttempted = true
	persistErr = writeJournal(s.path, s.state)
	s.mu.Unlock()
	if persistErr != nil {
		return persistErr
	}
	if _, _, err = s.arm.request(ctx, "PUT", path, payload); err != nil {
		return err
	}
	for {
		if err := pause(ctx, 5*time.Second); err != nil {
			return errors.New("worker_deployment_deadline_exhausted")
		}
		data, absent, err := s.arm.request(ctx, "GET", path, nil)
		if err != nil || absent {
			return errors.New("worker_deployment_status_failed")
		}
		var deployment struct {
			Properties struct {
				State string `json:"provisioningState"`
			} `json:"properties"`
		}
		if json.Unmarshal(data, &deployment) != nil {
			return errors.New("worker_deployment_status_invalid")
		}
		switch deployment.Properties.State {
		case "Succeeded":
			return nil
		case "Failed", "Canceled":
			return errors.New("worker_deployment_failed")
		case "Accepted", "Running":
		default:
			return errors.New("worker_deployment_state_invalid")
		}
	}
}

func (s *spikeScaler) cleanup(ctx context.Context) error {
	if !s.state.ScaleSetAttempted {
		if s.state.Worker != nil {
			return errors.New("controller_cleanup_state_invalid")
		}
		return nil
	}
	var cleanupErr error
	if s.state.Worker != nil {
		expected := expectedWorker(s.config.RunID, 1)
		if s.state.Worker.Name != expected.Name || s.state.Worker.VMID != expected.VMID ||
			s.state.Worker.NICID != expected.NICID || s.state.Worker.DiskID != expected.DiskID {
			return errors.New("worker_cleanup_ids_invalid")
		}
		resourceCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
		if s.state.Worker.DeploymentAttempted {
			cleanupErr = s.arm.settleWorkerDeployment(resourceCtx, s.config.RunID)
		}
		if cleanupErr == nil {
			cleanupErr = s.arm.removeWorker(resourceCtx, *s.state.Worker, s.config.RunID, s.config.Head)
		}
		cancel()
		runner, err := s.api.GetRunnerByName(ctx, s.state.Worker.Name)
		switch {
		case err != nil:
			cleanupErr = errors.Join(cleanupErr, errors.New("github_runner_cleanup_lookup_failed"))
		case runner == nil:
		case runner.Name != s.state.Worker.Name || runner.RunnerScaleSetID != s.state.ScaleSetID ||
			s.state.Worker.RunnerID > 0 && runner.ID != s.state.Worker.RunnerID:
			cleanupErr = errors.Join(cleanupErr, errors.New("github_runner_cleanup_ownership_failed"))
		default:
			if s.api.RemoveRunner(ctx, int64(runner.ID)) != nil {
				cleanupErr = errors.Join(cleanupErr, errors.New("github_runner_cleanup_failed"))
			} else if remaining, err := s.api.GetRunnerByName(ctx, s.state.Worker.Name); err != nil || remaining != nil {
				cleanupErr = errors.Join(cleanupErr, errors.New("github_runner_absence_unverified"))
			}
		}
		if cleanupErr == nil {
			s.state.Worker.Phase = "absence-verified"
			cleanupErr = writeJournal(s.path, s.state)
		}
	}
	name := "ghr-smoke-vmss-spike-" + s.config.RunID
	set, err := s.api.GetRunnerScaleSet(ctx, 1, name)
	if err != nil {
		return errors.Join(cleanupErr, errors.New("scale_set_cleanup_lookup_failed"))
	}
	if set == nil {
		return cleanupErr
	}
	if set.ID <= 0 || s.state.ScaleSetID != 0 && set.ID != s.state.ScaleSetID ||
		s.api.DeleteRunnerScaleSet(ctx, set.ID) != nil {
		return errors.Join(cleanupErr, errors.New("scale_set_cleanup_delete_failed"))
	}
	if remaining, err := s.api.GetRunnerScaleSet(ctx, 1, name); err != nil || remaining != nil {
		return errors.Join(cleanupErr, errors.New("scale_set_cleanup_absence_unverified"))
	}
	return cleanupErr
}

func runController(ctx context.Context, config controllerConfig, api *scaleset.Client, arm *armClient) (resultErr error) {
	const journalPath = "/var/lib/ghr-vmss/journal.json"
	template, err := os.ReadFile("/opt/ghr-vmss/worker.json")
	if err != nil || !json.Valid(template) || len(template) > 4*1024*1024 {
		return errors.New("worker_template_invalid")
	}
	hash := sha256.Sum256(template)
	if hex.EncodeToString(hash[:]) != config.TemplateSHA256 {
		return errors.New("worker_template_checksum_failed")
	}
	s := &spikeScaler{api: api, arm: arm, config: config, template: template, path: journalPath,
		workCtx: ctx, finished: make(chan error, 1)}
	s.state = controllerJournal{RunID: config.RunID, Head: config.Head, StartedUTC: config.StartedUTC, Attempts: 1}
	if _, err := os.Lstat(journalPath); !os.IsNotExist(err) {
		if readStrictJSON(journalPath, &s.state) != nil || s.state.RunID != config.RunID ||
			s.state.Head != config.Head || !s.state.StartedUTC.Equal(config.StartedUTC) ||
			s.state.Attempts < 1 || s.state.Attempts > 2 ||
			s.state.Attempts == 2 && s.state.Worker == nil {
			return errors.New("controller_resume_state_invalid")
		}
		cleanupCtx, cancel := context.WithDeadline(context.Background(), config.HardDeadlineUTC)
		defer cancel()
		if err := s.cleanup(cleanupCtx); err != nil {
			return err
		}
		return errors.New("controller_restart_cleanup_only")
	}
	if err := writeJournal(journalPath, s.state); err != nil {
		return err
	}
	name := "ghr-smoke-vmss-spike-" + config.RunID
	existing, err := api.GetRunnerScaleSet(ctx, 1, name)
	if err != nil || existing != nil {
		return errors.New("scale_set_lookup_or_ownership_failed")
	}
	s.state.ScaleSetAttempted = true
	if err := writeJournal(journalPath, s.state); err != nil {
		return err
	}
	defer func() {
		stop := time.Now().Add(10 * time.Minute)
		if config.HardDeadlineUTC.Before(stop) {
			stop = config.HardDeadlineUTC
		}
		cleanupCtx, cancel := context.WithDeadline(context.Background(), stop)
		defer cancel()
		if err := s.cleanup(cleanupCtx); err != nil {
			resultErr = errors.Join(resultErr, err)
		}
	}()
	set, err := api.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{
		Name: name, RunnerGroupID: 1, Labels: []scaleset.Label{{Name: name, Type: "System"}},
		RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true},
	})
	if err != nil || set == nil || set.ID <= 0 {
		return errors.New("scale_set_create_failed")
	}
	s.state.ScaleSetID = set.ID
	if err := writeJournal(journalPath, s.state); err != nil {
		return err
	}
	readback, err := api.GetRunnerScaleSet(ctx, 1, name)
	if err != nil || readback == nil || readback.ID != set.ID || len(readback.Labels) != 1 ||
		readback.Labels[0].Name != name {
		return errors.New("scale_set_custom_label_readback_failed")
	}
	session, err := api.MessageSessionClient(ctx, set.ID, "spike60-"+config.RunID)
	if err != nil {
		return errors.New("message_session_create_failed")
	}
	receiver, err := listener.New(session, listener.Config{
		ScaleSetID: set.ID, MaxRunners: 1, Logger: slog.New(slog.DiscardHandler),
	})
	if err != nil {
		closeCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if session.Close(closeCtx) != nil {
			return errors.New("message_session_cleanup_failed")
		}
		return errors.New("listener_configuration_failed")
	}
	workCtx, cancel := context.WithCancel(ctx)
	s.workCtx = workCtx
	receiverDone := make(chan error, 1)
	go func() { receiverDone <- receiver.Run(workCtx, s) }()
	listenerExited := false
	select {
	case resultErr = <-s.finished:
	case <-receiverDone:
		listenerExited = true
		resultErr = errors.New("listener_stopped")
	case <-ctx.Done():
		resultErr = errors.New("controller_work_deadline_or_signal")
	}
	cancel()
	// The session client's HTTP operations are bounded; join before cleanup so
	// no callback can start a new mutation concurrently with teardown.
	if !listenerExited {
		select {
		case <-receiverDone:
		case <-time.After(time.Minute):
			resultErr = errors.New("listener_shutdown_unverified")
		}
	}
	s.wg.Wait()
	closeCtx, closeCancel := context.WithTimeout(context.Background(), time.Minute)
	defer closeCancel()
	if session.Close(closeCtx) != nil {
		resultErr = errors.New("message_session_cleanup_failed")
	}
	return resultErr
}
