package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/actions/scaleset"
)

type fakeAPI struct {
	current       *scaleset.RunnerScaleSet
	createErr     bool
	deleteErr     bool
	lookupErr     bool
	invalidLabels bool
	retain        bool
	deleted       int
	deadCleanup   bool
}

func (f *fakeAPI) GetRunnerScaleSet(ctx context.Context, _ int, _ string) (*scaleset.RunnerScaleSet, error) {
	if f.lookupErr {
		return nil, errors.New("secret-provider-body")
	}
	return f.current, nil
}

func (f *fakeAPI) CreateRunnerScaleSet(_ context.Context, value *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error) {
	copy := *value
	copy.ID = 42
	if f.invalidLabels {
		copy.Labels = nil
	}
	f.current = &copy
	if f.createErr {
		return nil, errors.New("secret-jit-config")
	}
	return f.current, nil
}

func (f *fakeAPI) DeleteRunnerScaleSet(ctx context.Context, id int) error {
	f.deleted = id
	f.deadCleanup = ctx.Err() != nil
	if f.deleteErr {
		return errors.New("secret-private-key")
	}
	if !f.retain {
		f.current = nil
	}
	return nil
}

func (f *fakeAPI) GenerateJitRunnerConfig(context.Context, *scaleset.RunnerScaleSetJitRunnerSetting, int) (*scaleset.RunnerScaleSetJitRunnerConfig, error) {
	panic("compatibility probe must never mint JIT")
}

func TestProbe(t *testing.T) {
	for _, tc := range []struct {
		name string
		api  fakeAPI
		want string
	}{
		{"success", fakeAPI{}, ""},
		{"ambiguous_create", fakeAPI{createErr: true}, "scale_set_create_failed"},
		{"delete_failure", fakeAPI{deleteErr: true}, "scale_set_cleanup_delete_failed"},
		{"absence_failure", fakeAPI{retain: true}, "scale_set_cleanup_absence_unverified"},
		{"label_failure", fakeAPI{invalidLabels: true}, "scale_set_custom_label_readback_failed"},
		{"lookup_failure", fakeAPI{lookupErr: true}, "scale_set_lookup_failed"},
		{"foreign_set", fakeAPI{current: &scaleset.RunnerScaleSet{ID: 9}}, "scale_set_name_already_exists"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id, err := probe(context.Background(), &tc.api, "ghr-test")
			got := ""
			if err != nil {
				got = err.Error()
			}
			if got != tc.want || strings.Contains(got, "secret") {
				t.Fatalf("unexpected sanitized outcome: %q", got)
			}
			if tc.name != "lookup_failure" && tc.name != "foreign_set" &&
				(tc.api.deleted != 42 || id != 42 || tc.api.deadCleanup) {
				t.Fatal("exact owned scale set cleanup was not attempted with a live context")
			}
			if tc.name == "foreign_set" && tc.api.deleted != 0 {
				t.Fatal("deleted a pre-existing scale set")
			}
		})
	}
}

func TestCleanupSurvivesCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	api := &fakeAPI{createErr: true}
	_, err := probe(ctx, api, "ghr-test")
	if err == nil || api.deleted != 42 || api.deadCleanup {
		t.Fatal("cleanup must not share the experiment cancellation")
	}
}
