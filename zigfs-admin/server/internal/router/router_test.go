package router_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/handler"
	"zigfs-admin/server/internal/middleware"
	"zigfs-admin/server/internal/router"
)

type systemService struct {
	ready bool
}

type managementService struct{}

type authService struct{}

func (authService) Login(context.Context, contract.LoginRequest) (contract.LoginResponse, error) {
	return contract.LoginResponse{
		Token:     "zigfs-issued-token",
		TokenType: "Bearer",
		Username:  "zigfs-admin-user",
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	}, nil
}

func (authService) Session(context.Context) (contract.SessionResponse, error) {
	return contract.SessionResponse{
		Authenticated: true,
		Username:      "admin",
		ExpiresAt:     time.Now().Add(time.Hour).Unix(),
	}, nil
}

func (managementService) ListBuckets(context.Context) (contract.ListBucketsResponse, error) {
	return contract.ListBucketsResponse{}, nil
}

func (managementService) CreateBucket(context.Context, contract.CreateBucketRequest) (contract.Bucket, error) {
	return contract.Bucket{}, nil
}

func (managementService) DeleteBucket(context.Context, string) error { return nil }

func (managementService) GetBucketConfiguration(context.Context, string) (contract.BucketConfiguration, error) {
	return contract.BucketConfiguration{Name: "bucket", Versioning: "Unversioned"}, nil
}

func (managementService) UpdateBucketConfiguration(context.Context, string, contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error) {
	return contract.BucketConfiguration{Name: "bucket", Versioning: "Enabled"}, nil
}

func (managementService) ListObjectVersions(context.Context, string, string) (contract.ListObjectVersionsResponse, error) {
	return contract.ListObjectVersionsResponse{}, nil
}

func (managementService) ListObjects(context.Context, string, string, string) (contract.ListObjectsResponse, error) {
	return contract.ListObjectsResponse{}, nil
}

func (managementService) PresignObject(context.Context, contract.PresignObjectRequest) (contract.PresignObjectResponse, error) {
	return contract.PresignObjectResponse{}, nil
}

func (managementService) CreateMultipartUpload(context.Context, contract.CreateMultipartUploadRequest) (contract.MultipartUpload, error) {
	return contract.MultipartUpload{}, nil
}

func (managementService) ListMultipartUploads(context.Context, string, string, string, string) (contract.ListMultipartUploadsResponse, error) {
	return contract.ListMultipartUploadsResponse{}, nil
}

func (managementService) GetMultipartUpload(context.Context, string, string, string) (contract.MultipartUpload, error) {
	return contract.MultipartUpload{}, nil
}

func (managementService) CompleteMultipartUpload(context.Context, string, contract.CompleteMultipartUploadRequest) (contract.Object, error) {
	return contract.Object{}, nil
}

func (managementService) AbortMultipartUpload(context.Context, string, string, string) error {
	return nil
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

func (managementService) Storage(context.Context) (contract.StorageResponse, error) {
	return contract.StorageResponse{Measurement: "logical_object_bytes", Used: 20}, nil
}

func (managementService) StorageScanner(context.Context) (contract.StorageScannerStatus, error) {
	return contract.StorageScannerStatus{Partitions: 16, NextPartition: 3}, nil
}

func (managementService) RunStorageGC(context.Context) (contract.StorageScanReport, error) {
	return contract.StorageScanReport{Partitions: 1, RemovedGenerations: 2, RemovedBytes: 42}, nil
}

func (managementService) Health(context.Context) (contract.ManagementHealthResponse, error) {
	return contract.ManagementHealthResponse{Status: "ready", Recovery: "ready", Reason: "none", Actions: []string{}}, nil
}

func (managementService) Settings(context.Context) (contract.SettingsResponse, error) {
	return contract.SettingsResponse{S3Region: "us-east-1", ReloadRequired: true}, nil
}

func testEngine(ready bool) http.Handler {
	return router.New(
		handler.NewAuth(authService{}),
		handler.NewSystem(systemService{ready: ready}),
		handler.NewManagement(managementService{}),
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

func TestWebBrandAssetsAreServedBeforeSPAFallback(t *testing.T) {
	gin.SetMode(gin.TestMode)
	webRoot := t.TempDir()
	for _, asset := range []string{
		"zigfs-logo.svg",
		"favicon-32x32.png",
		"icon-192x192.png",
		"apple-touch-icon.png",
	} {
		if err := os.WriteFile(filepath.Join(webRoot, asset), []byte(asset), 0o644); err != nil {
			t.Fatalf("write %s: %v", asset, err)
		}
	}
	if err := os.WriteFile(filepath.Join(webRoot, "index.html"), []byte("<!doctype html>"), 0o644); err != nil {
		t.Fatalf("write index: %v", err)
	}

	engine := router.New(
		handler.NewAuth(authService{}),
		handler.NewSystem(systemService{ready: true}),
		handler.NewManagement(managementService{}),
		webRoot,
	)
	for _, asset := range []string{
		"zigfs-logo.svg",
		"favicon-32x32.png",
		"icon-192x192.png",
		"apple-touch-icon.png",
	} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, "/"+asset, nil)

		engine.ServeHTTP(recorder, request)

		if recorder.Code != http.StatusOK {
			t.Fatalf("expected %s status %d, got %d", asset, http.StatusOK, recorder.Code)
		}
		if body := recorder.Body.String(); body != asset {
			t.Fatalf("expected %s body, got %q", asset, body)
		}
	}
}

func TestSystemRequiresAdminSession(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/v1/system", nil)

	engine.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected status %d, got %d", http.StatusUnauthorized, recorder.Code)
	}
}

func TestLoginSetsZigFSSessionCookie(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/auth/login",
		strings.NewReader(`{"username":"admin","password":"zigfs-admin"}`),
	)
	request.Header.Set("Content-Type", "application/json")

	engine.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, recorder.Code)
	}
	cookies := recorder.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != middleware.AdminSessionCookie {
		t.Fatalf("expected ZigFS session cookie, got %+v", cookies)
	}
	if !cookies[0].HttpOnly || cookies[0].Value != "zigfs-issued-token" {
		t.Fatalf("unexpected session cookie: %+v", cookies[0])
	}
	if strings.Contains(recorder.Body.String(), "zigfs-issued-token") {
		t.Fatal("ZigFS token must not be exposed to browser JavaScript")
	}
	if !strings.Contains(recorder.Body.String(), `"username":"zigfs-admin-user"`) {
		t.Fatalf("expected ZigFS-confirmed identity, got %s", recorder.Body.String())
	}
}

func TestSystem(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/v1/system", nil)
	request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})

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

func TestManagementSummaryRoutes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	for _, path := range []string{"/api/v1/storage", "/api/v1/storage/scanner", "/api/v1/management-health", "/api/v1/settings"} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})

		engine.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusOK {
			t.Fatalf("expected %s status %d, got %d", path, http.StatusOK, recorder.Code)
		}
	}
}

func TestRunStorageGC(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/storage/gc", nil)
	request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})

	engine.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d: %s", http.StatusOK, recorder.Code, recorder.Body.String())
	}
	var response contract.StorageScanReport
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.RemovedGenerations != 2 || response.RemovedBytes != 42 {
		t.Fatalf("unexpected response: %+v", response)
	}
}

func TestCreateBucketAcceptsNameWithoutOwner(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/buckets",
		strings.NewReader(`{"name":"project-assets"}`),
	)
	request.Header.Set("Content-Type", "application/json")
	request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})

	engine.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}
}
