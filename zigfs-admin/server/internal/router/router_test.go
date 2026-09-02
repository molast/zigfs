package router_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/handler"
	"zigfs-admin/server/internal/router"
)

type systemService struct {
	ready bool
}

type managementService struct{}

func (managementService) ListBuckets(context.Context) (contract.ListBucketsResponse, error) {
	return contract.ListBucketsResponse{}, nil
}

func (managementService) CreateBucket(context.Context, contract.CreateBucketRequest) (contract.Bucket, error) {
	return contract.Bucket{}, nil
}

func (managementService) DeleteBucket(context.Context, string) error { return nil }

func (managementService) ListObjects(context.Context, string, string, string) (contract.ListObjectsResponse, error) {
	return contract.ListObjectsResponse{}, nil
}

func (managementService) PresignObject(context.Context, contract.PresignObjectRequest) (contract.PresignObjectResponse, error) {
	return contract.PresignObjectResponse{}, nil
}

func (managementService) ListAccessKeys(context.Context) (contract.ListAccessKeysResponse, error) {
	return contract.ListAccessKeysResponse{}, nil
}

func (managementService) CreateAccessKey(context.Context, contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	return contract.CreateAccessKeyResponse{}, nil
}

func (managementService) UpdateAccessKey(context.Context, string, contract.UpdateAccessKeyRequest) (contract.AccessKey, error) {
	return contract.AccessKey{}, nil
}

func (managementService) DeleteAccessKey(context.Context, string) error { return nil }

func testEngine(ready bool) http.Handler {
	return router.New(
		handler.NewSystem(systemService{ready: ready}),
		handler.NewManagement(managementService{}),
		"test-token",
		"testdata/web",
	)
}

func (service systemService) Ready(context.Context) error {
	if !service.ready {
		return context.DeadlineExceeded
	}
	return nil
}

func (systemService) Get(context.Context) (contract.SystemResponse, error) {
	return contract.SystemResponse{Version: "0.1.0", Buckets: 2, Objects: 4}, nil
}

func TestLive(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/health/live", nil)

	engine.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, recorder.Code)
	}
}

func TestSystemRequiresAdminToken(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/v1/system", nil)

	engine.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected status %d, got %d", http.StatusUnauthorized, recorder.Code)
	}
}

func TestSystem(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/v1/system", nil)
	request.Header.Set("Authorization", "Bearer test-token")

	engine.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, recorder.Code)
	}
	var response contract.SystemResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Buckets != 2 || response.Objects != 4 {
		t.Fatalf("unexpected response: %+v", response)
	}
}
