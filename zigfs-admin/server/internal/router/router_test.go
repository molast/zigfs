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

func (managementService) AssumeRole(context.Context, contract.AssumeRoleRequest) (contract.AssumeRoleResponse, error) {
	return contract.AssumeRoleResponse{}, nil
}
func (managementService) ListOrganizations(context.Context) (contract.OrganizationList, error) {
	return contract.OrganizationList{}, nil
}
func (managementService) CreateOrganization(context.Context, contract.Organization) (contract.Organization, error) {
	return contract.Organization{}, nil
}
func (managementService) UpdateOrganization(context.Context, contract.Organization) (contract.Organization, error) {
	return contract.Organization{}, nil
}
func (managementService) DeleteOrganization(context.Context, string) error { return nil }
func (managementService) ListRoles(context.Context) (contract.RoleList, error) {
	return contract.RoleList{}, nil
}
func (managementService) CreateRole(context.Context, contract.Role) (contract.Role, error) {
	return contract.Role{}, nil
}
func (managementService) UpdateRole(context.Context, contract.Role) (contract.Role, error) {
	return contract.Role{}, nil
}
func (managementService) DeleteRole(context.Context, string) error { return nil }
func (managementService) ListRoleSessions(context.Context) (contract.RoleSessionList, error) {
	return contract.RoleSessionList{}, nil
}
func (managementService) RevokeRoleSession(context.Context, string) error { return nil }

func (authService) Login(context.Context, contract.LoginRequest) (contract.LoginResponse, error) {
	return contract.LoginResponse{
		Token:     "zigfs-issued-token",
		TokenType: "Bearer",
		Username:  "zigfs-admin-user",
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	}, nil
}
func (authService) STSLogin(context.Context, contract.STSLoginRequest) (contract.LoginResponse, error) {
	return contract.LoginResponse{Token: "zigfs-issued-token", Username: "sts-user", ExpiresAt: time.Now().Add(time.Hour).Unix()}, nil
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

func (managementService) GetBucketUsage(context.Context, string) (contract.BucketUsage, error) {
	return contract.BucketUsage{}, nil
}

func (managementService) ListBucketEvents(context.Context, string, string, string, string, string, string, int) (contract.ListBucketEventsResponse, error) {
	return contract.ListBucketEventsResponse{}, nil
}
func (managementService) GetBucketPolicy(context.Context, string) (contract.BucketPolicy, error) {
	return contract.BucketPolicy{}, nil
}
func (managementService) PutBucketPolicy(context.Context, string, contract.BucketPolicy) (contract.BucketPolicy, error) {
	return contract.BucketPolicy{}, nil
}
func (managementService) DeleteBucketPolicy(context.Context, string) error { return nil }

func (managementService) GetBucketTags(context.Context, string) (contract.BucketTags, error) {
	return contract.BucketTags{}, nil
}
func (managementService) PutBucketTags(context.Context, string, contract.BucketTags) (contract.BucketTags, error) {
	return contract.BucketTags{}, nil
}
func (managementService) DeleteBucketTags(context.Context, string) error { return nil }

func (managementService) UpdateBucketConfiguration(context.Context, string, contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error) {
	return contract.BucketConfiguration{Name: "bucket", Versioning: "Enabled"}, nil
}

func (managementService) ListObjectVersions(context.Context, string, string) (contract.ListObjectVersionsResponse, error) {
	return contract.ListObjectVersionsResponse{}, nil
}

func (managementService) ListObjects(context.Context, string, string, string, string, string, string) (contract.ListObjectsResponse, error) {
	return contract.ListObjectsResponse{}, nil
}

func (managementService) CreateDirectory(context.Context, string, contract.CreateDirectoryRequest) (contract.Directory, error) {
	return contract.Directory{}, nil
}

func (managementService) DeleteDirectory(context.Context, string, contract.DeleteDirectoryRequest) error {
	return nil
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
	for _, path := range []string{"/api/v1/storage", "/api/v1/storage/scanner", "/api/v1/management-health", "/api/v1/settings", "/api/v1/settings/kms"} {
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

func (managementService) ListPolicies(ctx context.Context) (contract.PolicyList, error) {
	return contract.PolicyList{}, nil
}

func (managementService) GetPolicy(ctx context.Context, name string) (contract.ManagedPolicy, error) {
	return contract.ManagedPolicy{}, nil
}

func (managementService) CreatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error) {
	return contract.ManagedPolicy{}, nil
}

func (managementService) UpdatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error) {
	return contract.ManagedPolicy{}, nil
}

func (managementService) DeletePolicy(ctx context.Context, name string) error { return nil }

func TestPolicyRoutesRequireSessionAndValidateRename(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	for _, route := range []struct{ method, path string }{
		{"GET", "/api/v1/policies"}, {"POST", "/api/v1/policies"},
		{"GET", "/api/v1/policies/custom"}, {"PATCH", "/api/v1/policies/custom"},
		{"DELETE", "/api/v1/policies/custom"},
	} {
		response := httptest.NewRecorder()
		engine.ServeHTTP(response, httptest.NewRequest(route.method, route.path, nil))
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s: got %d", route.method, route.path, response.Code)
		}
	}
	response := httptest.NewRecorder()
	request := httptest.NewRequest("PATCH", "/api/v1/policies/custom", strings.NewReader(`{"name":"different","document":"{}"}`))
	request.Header.Set("Content-Type", "application/json")
	request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})
	engine.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("rename should fail: %d", response.Code)
	}
}

func (managementService) ListUsers(context.Context) (contract.UserList, error) {
	return contract.UserList{Items: []contract.ManagedUser{}}, nil
}
func (managementService) GetUser(ctx context.Context, name string) (contract.ManagedUser, error) {
	return contract.ManagedUser{Name: name, Enabled: true, Policies: []string{}}, nil
}
func (managementService) CreateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error) {
	return contract.ManagedUser{Name: value.Name, Enabled: value.Enabled, Policies: value.Policies}, nil
}
func (managementService) UpdateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error) {
	return contract.ManagedUser{Name: value.Name, Enabled: value.Enabled, Policies: value.Policies}, nil
}
func (managementService) DeleteUser(context.Context, string) error { return nil }

func (managementService) ListGroups(context.Context) (contract.GroupList, error) {
	return contract.GroupList{Items: []contract.ManagedGroup{}}, nil
}
func (managementService) GetGroup(ctx context.Context, name string) (contract.ManagedGroup, error) {
	return contract.ManagedGroup{Name: name, Enabled: true, Policies: []string{}}, nil
}
func (managementService) CreateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error) {
	return value, nil
}
func (managementService) UpdateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error) {
	return value, nil
}
func (managementService) DeleteGroup(context.Context, string) error { return nil }

func TestIdentityRoutesRequireSessionAndValidatePayloads(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	for _, kind := range []string{"users", "groups"} {
		for _, route := range []struct{ method, suffix string }{{"GET", ""}, {"POST", ""}, {"GET", "/alice"}, {"PATCH", "/alice"}, {"DELETE", "/alice"}} {
			response := httptest.NewRecorder()
			engine.ServeHTTP(response, httptest.NewRequest(route.method, "/api/v1/"+kind+route.suffix, nil))
			if response.Code != http.StatusUnauthorized {
				t.Fatalf("%s %s: got %d", route.method, kind, response.Code)
			}
		}
		for _, tc := range []struct {
			method, suffix, body string
			status               int
		}{
			{"POST", "", `{"name":"alice","password":"test-password","enabled":true,"policies":["readonly"],"members":["bob"]}`, http.StatusCreated},
			{"PATCH", "/alice", `{"name":"alice","enabled":false,"policies":[],"members":[]}`, http.StatusOK},
			{"PATCH", "/alice", `{"name":"renamed"}`, http.StatusBadRequest},
			{"POST", "", `{"name":""}`, http.StatusBadRequest},
			{"POST", "", `{`, http.StatusBadRequest},
			{"GET", "/alice", ``, http.StatusOK},
			{"DELETE", "/alice", ``, http.StatusNoContent},
		} {
			response := httptest.NewRecorder()
			request := httptest.NewRequest(tc.method, "/api/v1/"+kind+tc.suffix, strings.NewReader(tc.body))
			request.Header.Set("Content-Type", "application/json")
			request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})
			engine.ServeHTTP(response, request)
			if response.Code != tc.status {
				t.Fatalf("%s %s: got %d: %s", tc.method, kind, response.Code, response.Body.String())
			}
			if tc.method == "POST" && tc.status == http.StatusCreated {
				var created contract.ManagedGroup
				if err := json.Unmarshal(response.Body.Bytes(), &created); err != nil {
					t.Fatal(err)
				}
				if !created.Enabled || len(created.Policies) != 1 || created.Policies[0] != "readonly" {
					t.Fatalf("lost fields: %+v", created)
				}
				if kind == "groups" && (len(created.Members) != 1 || created.Members[0] != "bob") {
					t.Fatalf("lost members: %+v", created)
				}
			}
		}
	}
}

func (managementService) ListUserAccessKeys(context.Context, string) (contract.ListAccessKeysResponse, error) {
	return contract.ListAccessKeysResponse{}, nil
}
func (managementService) CreateUserAccessKey(context.Context, string, contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	return contract.CreateAccessKeyResponse{}, nil
}
func (managementService) UpdateUserAccessKey(context.Context, string, string, contract.UpdateAccessKeyRequest) (contract.AccessKey, error) {
	return contract.AccessKey{}, nil
}
func (managementService) DeleteUserAccessKey(context.Context, string, string) error { return nil }

func (managementService) OIDCProviders(context.Context, string, string, json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{"items":[]}`), nil
}

func (managementService) OIDCAuth(context.Context, string, string, json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{"items":[]}`), nil
}

func (authService) Logout(context.Context) error { return nil }

func TestDirectoryOperationRoutes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	for _, test := range []struct {
		method, path, body string
		status             int
	}{
		{http.MethodDelete, "/api/v1/buckets/photos/directories?key=folder%2F&all_versions=true", "", http.StatusNoContent},
		{http.MethodDelete, "/api/v1/buckets/photos/directories?key=folder%2F&all_versions=invalid", "", http.StatusBadRequest},
		{http.MethodPost, "/api/v1/buckets/photos/directories/cleanup", `{"key":"folder/"}`, http.StatusNoContent},
		{http.MethodPost, "/api/v1/buckets/photos/directories/cleanup", `{}`, http.StatusBadRequest},
	} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
		request.Header.Set("Content-Type", "application/json")
		request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})
		engine.ServeHTTP(recorder, request)
		if recorder.Code != test.status {
			t.Errorf("%s %s: got %d, want %d: %s", test.method, test.path, recorder.Code, test.status, recorder.Body.String())
		}
	}
}

func (managementService) KMSSettings(context.Context) (contract.KMSStatus, error) {
	return contract.KMSStatus{}, nil
}
func (managementService) SaveKMSSettings(context.Context, contract.KMSConfig) (contract.KMSStatus, error) {
	return contract.KMSStatus{Configured: true}, nil
}

func TestKMSConfigurationRequiresSession(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(method, "/api/v1/settings/kms", nil)
		engine.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s: expected 401, got %d", method, recorder.Code)
		}
	}
}

func (managementService) StartKMS(context.Context) (contract.KMSStatus, error) {
	return contract.KMSStatus{Configured: true, State: "running", Healthy: true, HealthChecked: true}, nil
}

func TestKMSStartRouteAndSession(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	for _, authenticated := range []bool{false, true} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/api/v1/settings/kms/start", nil)
		if authenticated {
			request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "zigfs-issued-token"})
		}
		engine.ServeHTTP(recorder, request)
		expected := http.StatusUnauthorized
		if authenticated {
			expected = http.StatusOK
		}
		if recorder.Code != expected {
			t.Fatalf("got %d want %d: %s", recorder.Code, expected, recorder.Body.String())
		}
		if authenticated && !strings.Contains(recorder.Body.String(), `"state":"running"`) {
			t.Fatal(recorder.Body.String())
		}
	}
}

func (managementService) StopKMS(context.Context) (contract.KMSStatus, error) {
	return contract.KMSStatus{Configured: true, State: "configured"}, nil
}

func (managementService) ClearKMSCache(context.Context) (contract.KMSStatus, error) {
	return contract.KMSStatus{Configured: true, State: "configured"}, nil
}

func (managementService) KMSKeys(context.Context, string, bool, json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{"items":[],"canCreate":true,"canRekey":false}`), nil
}

func TestKMSRuntimeAndKeyRoutesRequireSession(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := testEngine(true)
	for _, path := range []string{"/api/v1/settings/kms/stop", "/api/v1/settings/kms/clear-cache", "/api/v1/settings/kms/keys", "/api/v1/settings/kms/keys/action"} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{}`))
		request.Header.Set("Content-Type", "application/json")
		engine.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s returned %d", path, recorder.Code)
		}
	}
}

func (managementService) AuditLogSettings(context.Context, string, string, json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{"output":"file","directory":"audit-logs"}`), nil
}

func (managementService) LogSettings(context.Context, string, string, json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{"level":"info","directory":"logs"}`), nil
}

func (managementService) AuditEvents(context.Context, string, string) (json.RawMessage, error) {
	return json.RawMessage(`{"items":[]}`), nil
}
