package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func validControllerConfig(now time.Time) controllerConfig {
	return controllerConfig{
		RunID: strings.Repeat("a", 32), Head: strings.Repeat("b", 40),
		StartedUTC: now, WorkDeadlineUTC: now.Add(3 * time.Hour), HardDeadlineUTC: now.Add(4 * time.Hour),
		FoundationAttempts: 1, InstallationID: 1, SecretVersion: strings.Repeat("c", 32),
		TemplateSHA256: strings.Repeat("d", 64),
	}
}

func TestControllerOriginalClock(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	config := validControllerConfig(now)
	if err := config.validate(now); err != nil {
		t.Fatal(err)
	}
	config.FoundationAttempts = 2
	if config.validate(now) == nil {
		t.Fatal("worker invocation allowed after two foundation calls")
	}
	config.FoundationAttempts = 1
	if config.validate(now.Add(2*time.Hour+11*time.Minute)) == nil {
		t.Fatal("worker provisioning consumed cleanup reserve")
	}
	config.HardDeadlineUTC = now.Add(5 * time.Hour)
	if config.validate(now) == nil {
		t.Fatal("original lifetime increased")
	}
}

func TestAtomicJournalAndStrictRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.json")
	state := controllerJournal{RunID: strings.Repeat("a", 32), Head: strings.Repeat("b", 40), Attempts: 2}
	if err := writeJournal(path, state); err != nil {
		t.Fatal(err)
	}
	var loaded controllerJournal
	if readStrictJSON(path, &loaded) != nil || loaded.Attempts != 2 {
		t.Fatal("attempt reservation not durable")
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("journal permissions not private")
	}
	if os.WriteFile(path, []byte(`{"unexpected":"fake-secret"}`), 0600) != nil ||
		readStrictJSON(path, &loaded) == nil {
		t.Fatal("unexpected journal fields accepted")
	}
	if os.WriteFile(path, []byte(`{} {}`), 0600) != nil || readStrictJSON(path, &loaded) == nil {
		t.Fatal("trailing JSON accepted")
	}
}

func TestCallbacksCorrelateExactlyOneJobAndRedelivery(t *testing.T) {
	worker := expectedWorker(strings.Repeat("a", 32), 1)
	worker.RunnerID = 12
	s := &spikeScaler{
		state: controllerJournal{Attempts: 2, Worker: &worker},
		path:  filepath.Join(t.TempDir(), "journal.json"), workCtx: context.Background(),
		finished: make(chan error, 1),
	}
	if capacity, err := s.HandleDesiredRunnerCount(context.Background(), 100); err != nil || capacity != 1 {
		t.Fatal("literal remaining budget advertised more than one worker")
	}
	job := &scaleset.JobStarted{RunnerID: 12, RunnerName: worker.Name,
		JobMessageBase: scaleset.JobMessageBase{RunnerRequestID: 99}}
	if s.HandleJobStarted(context.Background(), job) != nil ||
		s.HandleJobStarted(context.Background(), job) != nil {
		t.Fatal("valid lifecycle/redelivery rejected")
	}
	job.RunnerRequestID = 100
	if s.HandleJobStarted(context.Background(), job) == nil {
		t.Fatal("second job admitted")
	}
	completed := &scaleset.JobCompleted{RunnerID: 12, RunnerName: worker.Name,
		JobMessageBase: scaleset.JobMessageBase{RunnerRequestID: 99}}
	if s.HandleJobCompleted(context.Background(), completed) != nil ||
		s.HandleJobCompleted(context.Background(), completed) != nil || !worker.JobComplete {
		t.Fatal("completion/redelivery not idempotent")
	}
	completed.RunnerID = 13
	if s.HandleJobCompleted(context.Background(), completed) == nil {
		t.Fatal("foreign runner completion admitted")
	}
	data, _ := json.Marshal(s.state)
	if strings.Contains(string(data), "encodedJIT") {
		t.Fatal("JIT included in durable journal")
	}
}

func TestExhaustedReservationNeverCreatesAnotherWorker(t *testing.T) {
	s := &spikeScaler{workCtx: context.Background(), state: controllerJournal{Attempts: 2}}
	if _, err := s.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("aggregate create cap not enforced")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s.workCtx = ctx
	if _, err := s.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("scaling after cancellation accepted")
	}
}

func TestUnattemptedScaleSetNeverTouchedOnRecovery(t *testing.T) {
	s := &spikeScaler{state: controllerJournal{Attempts: 1}}
	if err := s.cleanup(context.Background()); err != nil {
		t.Fatal("unattempted namespace should require no API access")
	}
}

func TestConcurrentDemandReservesOnlyOneInvocation(t *testing.T) {
	now := time.Now().UTC()
	config := validControllerConfig(now)
	s := &spikeScaler{
		config: config, state: controllerJournal{RunID: config.RunID, Head: config.Head, Attempts: 1},
		path: filepath.Join(t.TempDir(), "journal.json"), workCtx: context.Background(),
		finished: make(chan error, 1),
	}
	var callers sync.WaitGroup
	for range 20 {
		callers.Add(1)
		go func() {
			defer callers.Done()
			if capacity, err := s.HandleDesiredRunnerCount(context.Background(), 100); err != nil || capacity != 1 {
				t.Error("concurrent demand escaped the single-worker boundary")
			}
		}()
	}
	callers.Wait()
	s.wg.Wait()
	var persisted controllerJournal
	if readStrictJSON(s.path, &persisted) != nil || persisted.Attempts != 2 ||
		persisted.Worker == nil || persisted.Worker.Name != expectedWorker(config.RunID, 1).Name ||
		persisted.Worker.DeploymentAttempted {
		t.Fatal("reservation not durable or invalid parameters reached deployment")
	}
}
