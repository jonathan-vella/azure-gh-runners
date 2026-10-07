package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

func testArm(status int, body string) (*armClient, *int) {
	calls := new(int)
	return &armClient{
		token: func(context.Context, string) (string, error) { return "fake-token", nil },
		http: &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
			*calls++
			return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}, nil
		})},
	}, calls
}

func TestArmScopeAndSanitization(t *testing.T) {
	a, calls := testArm(403, `{"message":"fake-provider-secret"}`)
	id := expectedWorker(strings.Repeat("a", 32), 1).VMID + "?api-version=2024-07-01"
	for _, tc := range []struct{ method, path string }{
		{"POST", id},
		{"PUT", id},
		{"DELETE", "/subscriptions/other/resourceGroups/prod"},
		{"GET", spikeScope + "/providers/Microsoft.Authorization/roleAssignments/any"},
		{"GET", spikeScope + "/providers/Microsoft.Compute/virtualMachines/%2e%2e"},
	} {
		if _, _, err := a.request(context.Background(), tc.method, tc.path, nil); err == nil {
			t.Fatal("unapproved ARM operation accepted")
		}
	}
	if *calls != 0 {
		t.Fatal("invalid operation reached HTTP transport")
	}
	_, _, err := a.request(context.Background(), http.MethodGet, id, nil)
	if err == nil || err.Error() != "arm_operation_failed" || *calls != 1 {
		t.Fatal("provider error leaked or request retried")
	}
}

func TestWorkerCleanupRefusesForeignIDsAndTags(t *testing.T) {
	runID := strings.Repeat("a", 32)
	head := strings.Repeat("b", 40)
	a, calls := testArm(200, `{"id":"foreign","tags":{"spike-id":"60"}}`)
	worker := expectedWorker(runID, 1)
	if err := a.removeWorker(context.Background(), worker, runID, head); err == nil ||
		err.Error() != "worker_cleanup_ownership_failed" || *calls != 1 {
		t.Fatal("foreign resource deletion was allowed")
	}
	worker.NICID = spikeScope + "/providers/Microsoft.Network/networkInterfaces/other"
	if err := a.removeWorker(context.Background(), worker, runID, head); err == nil ||
		err.Error() != "worker_cleanup_ids_invalid" || *calls != 1 {
		t.Fatal("unrecorded resource was contacted")
	}
	a, calls = testArm(404, "")
	if err := a.removeWorker(context.Background(), expectedWorker(runID, 1), runID, head); err != nil || *calls != 3 {
		t.Fatal("partial/already-absent worker cleanup is not idempotent")
	}
}

func TestPollCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := pause(ctx, time.Hour); !errors.Is(err, context.Canceled) {
		t.Fatal("poll ignored cancellation")
	}

}

func TestPendingDeploymentCanceledOnceBeforeCleanup(t *testing.T) {
	runID := strings.Repeat("a", 32)
	gets, cancels := 0, 0
	a := &armClient{
		token: func(context.Context, string) (string, error) { return "fake-token", nil },
		http: &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
			body := ""
			switch request.Method {
			case http.MethodGet:
				gets++
				body = `{"properties":{"provisioningState":"Running"}}`
				if gets == 2 {
					body = `{"properties":{"provisioningState":"Canceled"}}`
				}
			case http.MethodPost:
				cancels++
				if !strings.HasSuffix(request.URL.Path, "/cancel") {
					t.Fatal("unexpected mutation")
				}
			default:
				t.Fatal("create/delete before pending deployment was settled")
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := a.settleWorkerDeployment(ctx, runID); err != nil || gets != 2 || cancels != 1 {
		t.Fatal("pending deployment was not reconciled with exactly one cancel")
	}
}

func TestDispatchedDeploymentAbsenceIsNotProof(t *testing.T) {
	a, calls := testArm(404, "")
	err := a.settleWorkerDeployment(context.Background(), strings.Repeat("a", 32))
	if err == nil || err.Error() != "deployment_cleanup_absence_ambiguous" || *calls != 1 {
		t.Fatal("ambiguous create was silently certified absent or retried")
	}
}
