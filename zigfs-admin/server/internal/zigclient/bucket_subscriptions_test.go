package zigclient_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/zigclient"
)

func TestBucketEventSubscriptionsForwarding(t *testing.T) {
	value := contract.BucketEventSubscriptions{Items: []contract.BucketEventSubscription{{ID: "test-1", Destination: "WEBHOOK_1", Prefix: "photos/", Suffix: ".png", Events: []string{"PUT", "DELETE"}}}}
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/_admin/v1/buckets/photos/event-subscriptions" || r.Header.Get("Authorization") != "Bearer session-token" {
			t.Errorf("unexpected forwarding: %s", r.URL.Path)
		}
		if r.Method == http.MethodPut {
			var input contract.BucketEventSubscriptions
			if err := json.NewDecoder(r.Body).Decode(&input); err != nil || !reflect.DeepEqual(value, input) {
				t.Errorf("invalid request: %+v %v", input, err)
			}
		} else if r.Method != http.MethodGet {
			t.Errorf("unexpected method %s", r.Method)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(value)
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	ctx := managementauth.WithToken(context.Background(), "session-token")
	got, err := client.GetBucketEventSubscriptions(ctx, "photos")
	if err != nil || !reflect.DeepEqual(got, value) {
		t.Fatalf("GET: %+v %v", got, err)
	}
	got, err = client.PutBucketEventSubscriptions(ctx, "photos", value)
	if err != nil || !reflect.DeepEqual(got, value) {
		t.Fatalf("PUT: %+v %v", got, err)
	}
	if calls != 2 {
		t.Fatalf("calls: %d", calls)
	}
}
