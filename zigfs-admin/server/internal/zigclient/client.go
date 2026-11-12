package zigclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/port"
	"zigfs-admin/server/internal/requestid"
)

type Client struct {
	endpointMu sync.RWMutex
	candidates []string
	endpoint   string
	httpClient *http.Client
}

func New(endpoint string, timeout time.Duration) *Client {
	return &Client{
		endpoint:   endpoint,
		httpClient: &http.Client{Timeout: timeout},
	}
}

func (client *Client) Ready(ctx context.Context) error {
	return client.requestJSON(ctx, http.MethodGet, "/health/ready", nil, nil)
}

func (client *Client) Login(ctx context.Context, request contract.LoginRequest) (contract.LoginResponse, error) {
	var response contract.LoginResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/auth/login", request, &response)
	return response, err
}
func (client *Client) STSLogin(ctx context.Context, request contract.STSLoginRequest) (contract.LoginResponse, error) {
	var response contract.LoginResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/auth/sts-login", request, &response)
	return response, err
}

func (client *Client) Session(ctx context.Context) (contract.SessionResponse, error) {
	var response contract.SessionResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/auth/session", nil, &response)
	return response, err
}

func (client *Client) System(ctx context.Context) (contract.SystemResponse, error) {
	var response contract.SystemResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/system", nil, &response)
	return response, err
}

func (client *Client) Storage(ctx context.Context) (contract.StorageResponse, error) {
	var response contract.StorageResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/storage", nil, &response)
	return response, err
}

func (client *Client) StorageScanner(ctx context.Context) (contract.StorageScannerStatus, error) {
	var response contract.StorageScannerStatus
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/storage/scanner", nil, &response)
	return response, err
}

func (client *Client) RunStorageGC(ctx context.Context) (contract.StorageScanReport, error) {
	var response contract.StorageScanReport
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/storage/gc", nil, &response)
	return response, err
}

func (client *Client) ManagementHealth(ctx context.Context) (contract.ManagementHealthResponse, error) {
	var response contract.ManagementHealthResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/health", nil, &response)
	return response, err
}

func (client *Client) Settings(ctx context.Context) (contract.SettingsResponse, error) {
	var response contract.SettingsResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/settings", nil, &response)
	return response, err
}

func (client *Client) ListBuckets(ctx context.Context) (contract.ListBucketsResponse, error) {
	var response contract.ListBucketsResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/buckets", nil, &response)
	return response, err
}

func (client *Client) CreateBucket(ctx context.Context, request contract.CreateBucketRequest) (contract.Bucket, error) {
	var response contract.Bucket
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/buckets", request, &response)
	return response, err
}

func (client *Client) DeleteBucket(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/buckets/"+url.PathEscape(name), nil, nil)
}

func (client *Client) GetBucketConfiguration(ctx context.Context, name string) (contract.BucketConfiguration, error) {
	var response contract.BucketConfiguration
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/buckets/"+url.PathEscape(name)+"/configuration", nil, &response)
	return response, err
}

func (client *Client) GetBucketUsage(ctx context.Context, name string) (contract.BucketUsage, error) {
	var response contract.BucketUsage
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/buckets/"+url.PathEscape(name)+"/usage", nil, &response)
	return response, err
}

func (client *Client) ListBucketEvents(ctx context.Context, name, cursor, from, to, action, outcome string, limit int) (contract.ListBucketEventsResponse, error) {
	var response contract.ListBucketEventsResponse
	query := url.Values{}
	if cursor != "" {
		query.Set("cursor", cursor)
	}
	if from != "" {
		query.Set("from", from)
	}
	if to != "" {
		query.Set("to", to)
	}
	if action != "" {
		query.Set("action", action)
	}
	if outcome != "" {
		query.Set("outcome", outcome)
	}
	if limit > 0 {
		query.Set("limit", strconv.Itoa(limit))
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(name) + "/events"
	if name == "" {
		path = "/_admin/v1/audit-events"
	}
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}
func (client *Client) GetBucketPolicy(ctx context.Context, name string) (contract.BucketPolicy, error) {
	var response contract.BucketPolicy
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/buckets/"+url.PathEscape(name)+"/policy", nil, &response)
	return response, err
}
func (client *Client) PutBucketPolicy(ctx context.Context, name string, tags contract.BucketPolicy) (contract.BucketPolicy, error) {
	var response contract.BucketPolicy
	err := client.requestJSON(ctx, http.MethodPut, "/_admin/v1/buckets/"+url.PathEscape(name)+"/policy", tags, &response)
	return response, err
}
func (client *Client) DeleteBucketPolicy(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/buckets/"+url.PathEscape(name)+"/policy", nil, nil)
}

func (client *Client) GetBucketTags(ctx context.Context, name string) (contract.BucketTags, error) {
	var response contract.BucketTags
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/buckets/"+url.PathEscape(name)+"/tags", nil, &response)
	return response, err
}
func (client *Client) PutBucketTags(ctx context.Context, name string, tags contract.BucketTags) (contract.BucketTags, error) {
	var response contract.BucketTags
	err := client.requestJSON(ctx, http.MethodPut, "/_admin/v1/buckets/"+url.PathEscape(name)+"/tags", tags, &response)
	return response, err
}
func (client *Client) DeleteBucketTags(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/buckets/"+url.PathEscape(name)+"/tags", nil, nil)
}

func (client *Client) UpdateBucketConfiguration(ctx context.Context, name string, request contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error) {
	var response contract.BucketConfiguration
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/buckets/"+url.PathEscape(name)+"/configuration", request, &response)
	return response, err
}

func (client *Client) ListObjectVersions(ctx context.Context, bucket, prefix string) (contract.ListObjectVersionsResponse, error) {
	query := url.Values{}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(bucket) + "/versions"
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}
	var response contract.ListObjectVersionsResponse
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}

func (client *Client) ListObjects(ctx context.Context, bucket, prefix, search, cursor, maxKeys, delimiter string) (contract.ListObjectsResponse, error) {
	query := url.Values{}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	if search != "" {
		query.Set("search", search)
	}
	if cursor != "" {
		query.Set("continuation_token", cursor)
	}
	if maxKeys != "" {
		query.Set("max_keys", maxKeys)
	}
	if delimiter != "" {
		query.Set("delimiter", delimiter)
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(bucket) + "/objects"
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}

	var response contract.ListObjectsResponse
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}

func (client *Client) CreateDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) (contract.Directory, error) {
	var response contract.Directory
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/buckets/"+url.PathEscape(bucket)+"/directories", request, &response)
	return response, err
}

func (client *Client) DeleteDirectory(ctx context.Context, bucket string, request contract.DeleteDirectoryRequest) error {
	if request.ForceCleanup {
		return client.requestJSON(ctx, http.MethodPost, "/_admin/v1/buckets/"+url.PathEscape(bucket)+"/directories/cleanup", request, nil)
	}
	query := url.Values{"key": {request.Key}}
	if request.AllVersions {
		query.Set("all_versions", "true")
	}
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/buckets/"+url.PathEscape(bucket)+"/directories?"+query.Encode(), nil, nil)
}

func (client *Client) PresignObject(ctx context.Context, request contract.PresignObjectRequest) (contract.PresignObjectResponse, error) {
	var response contract.PresignObjectResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/objects/presign", request, &response)
	return response, err
}

func (client *Client) CreateMultipartUpload(ctx context.Context, request contract.CreateMultipartUploadRequest) (contract.MultipartUpload, error) {
	var response contract.MultipartUpload
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/multipart-uploads", request, &response)
	return response, err
}

func (client *Client) ListMultipartUploads(ctx context.Context, bucket, prefix, keyMarker, uploadIDMarker string) (contract.ListMultipartUploadsResponse, error) {
	query := url.Values{}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	if keyMarker != "" {
		query.Set("key_marker", keyMarker)
	}
	if uploadIDMarker != "" {
		query.Set("upload_id_marker", uploadIDMarker)
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(bucket) + "/multipart-uploads"
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}
	var response contract.ListMultipartUploadsResponse
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}

func (client *Client) GetMultipartUpload(ctx context.Context, uploadID, bucket, key string) (contract.MultipartUpload, error) {
	query := url.Values{"bucket": {bucket}, "key": {key}}
	var response contract.MultipartUpload
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/multipart-uploads/"+url.PathEscape(uploadID)+"?"+query.Encode(), nil, &response)
	return response, err
}

func (client *Client) CompleteMultipartUpload(ctx context.Context, uploadID string, request contract.CompleteMultipartUploadRequest) (contract.Object, error) {
	var response contract.Object
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/multipart-uploads/"+url.PathEscape(uploadID)+"/complete", request, &response)
	return response, err
}

func (client *Client) AbortMultipartUpload(ctx context.Context, uploadID, bucket, key string) error {
	query := url.Values{"bucket": {bucket}, "key": {key}}
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/multipart-uploads/"+url.PathEscape(uploadID)+"?"+query.Encode(), nil, nil)
}

func (client *Client) ListAccessKeys(ctx context.Context) (contract.ListAccessKeysResponse, error) {
	var response contract.ListAccessKeysResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/access-keys", nil, &response)
	return response, err
}

func (client *Client) CreateAccessKey(ctx context.Context, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	var response contract.CreateAccessKeyResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/access-keys", request, &response)
	return response, err
}

func (client *Client) UpdateAccessKey(ctx context.Context, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error) {
	var response contract.AccessKey
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/access-keys/"+url.PathEscape(id), request, &response)
	return response, err
}

func (client *Client) DeleteAccessKey(ctx context.Context, id string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/access-keys/"+url.PathEscape(id), nil, nil)
}

func (client *Client) requestJSON(ctx context.Context, method, path string, body, target any) error {
	var payload *bytes.Reader
	if body == nil {
		payload = bytes.NewReader(nil)
	} else {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode zig request: %w", err)
		}
		payload = bytes.NewReader(encoded)
	}

	request, err := http.NewRequestWithContext(ctx, method, client.Endpoint()+path, payload)
	if err != nil {
		return fmt.Errorf("create zig request: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	if origin := managementauth.Forwarded(ctx); origin.For != "" {
		request.Header.Set("X-Forwarded-For", origin.For)
		request.Header.Set("X-Forwarded-Proto", origin.Proto)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if token := managementauth.Token(ctx); token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if id := requestid.FromContext(ctx); id != "" {
		request.Header.Set("X-Request-ID", id)
	}

	response, err := client.httpClient.Do(request)
	if err != nil && dialFailure(err) {
		client.endpointMu.RLock()
		candidates := append([]string(nil), client.candidates...)
		client.endpointMu.RUnlock()
		for _, candidate := range candidates {
			if candidate == request.URL.Scheme+"://"+request.URL.Host {
				continue
			}
			retry := request.Clone(ctx)
			retry.URL, _ = url.Parse(candidate + path)
			if request.GetBody != nil {
				retry.Body, err = request.GetBody()
				if err != nil {
					break
				}
			}
			response, err = client.httpClient.Do(retry)
			if err == nil {
				client.endpointMu.Lock()
				client.endpoint = candidate
				client.endpointMu.Unlock()
				break
			}
			if !dialFailure(err) {
				break
			}
		}
	}
	if err != nil {
		return fmt.Errorf("call zig service: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		var upstream contract.ErrorResponse
		_ = json.NewDecoder(io.LimitReader(response.Body, 1024*1024)).Decode(&upstream)
		return &port.StatusError{
			StatusCode: response.StatusCode,
			Code:       upstream.Code,
			Message:    upstream.Message,
			RequestID:  upstream.RequestID,
		}
	}
	if target == nil || response.StatusCode == http.StatusNoContent {
		return nil
	}
	if err = json.NewDecoder(response.Body).Decode(target); err != nil {
		return fmt.Errorf("decode zig response: %w", err)
	}
	return nil
}

func (client *Client) ListPolicies(ctx context.Context) (contract.PolicyList, error) {
	var response contract.PolicyList
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/policies", nil, &response)
	return response, err
}

func (client *Client) GetPolicy(ctx context.Context, name string) (contract.ManagedPolicy, error) {
	var response contract.ManagedPolicy
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/policies/"+url.PathEscape(name), nil, &response)
	return response, err
}

func (client *Client) CreatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error) {
	var response contract.ManagedPolicy
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/policies", policy, &response)
	return response, err
}

func (client *Client) UpdatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error) {
	var response contract.ManagedPolicy
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/policies/"+url.PathEscape(policy.Name), policy, &response)
	return response, err
}

func (client *Client) DeletePolicy(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/policies/"+url.PathEscape(name), nil, nil)
}

func (client *Client) ListOrganizations(ctx context.Context) (contract.OrganizationList, error) {
	var out contract.OrganizationList
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/organizations", nil, &out)
	return out, err
}
func (client *Client) CreateOrganization(ctx context.Context, value contract.Organization) (contract.Organization, error) {
	var out contract.Organization
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/organizations", value, &out)
	return out, err
}
func (client *Client) UpdateOrganization(ctx context.Context, value contract.Organization) (contract.Organization, error) {
	var out contract.Organization
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/organizations/"+url.PathEscape(value.Name), value, &out)
	return out, err
}
func (client *Client) DeleteOrganization(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/organizations/"+url.PathEscape(name), nil, nil)
}
func (client *Client) ListRoles(ctx context.Context) (contract.RoleList, error) {
	var out contract.RoleList
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/roles", nil, &out)
	return out, err
}
func (client *Client) CreateRole(ctx context.Context, value contract.Role) (contract.Role, error) {
	var out contract.Role
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/roles", value, &out)
	return out, err
}
func (client *Client) UpdateRole(ctx context.Context, value contract.Role) (contract.Role, error) {
	var out contract.Role
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/roles/"+url.PathEscape(value.Name), value, &out)
	return out, err
}
func (client *Client) DeleteRole(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/roles/"+url.PathEscape(name), nil, nil)
}
func (client *Client) AssumeRole(ctx context.Context, request contract.AssumeRoleRequest) (contract.AssumeRoleResponse, error) {
	var out contract.AssumeRoleResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/sts/assume-role", request, &out)
	return out, err
}
func (client *Client) ListRoleSessions(ctx context.Context) (contract.RoleSessionList, error) {
	var out contract.RoleSessionList
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/role-sessions", nil, &out)
	return out, err
}
func (client *Client) RevokeRoleSession(ctx context.Context, accessKey string) error {
	return client.requestJSON(ctx, http.MethodPost, "/_admin/v1/role-sessions/"+url.PathEscape(accessKey)+"/revoke", nil, nil)
}

func (client *Client) ListUsers(ctx context.Context) (contract.UserList, error) {
	var response contract.UserList
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/users", nil, &response)
	return response, err
}

func (client *Client) GetUser(ctx context.Context, name string) (contract.ManagedUser, error) {
	var response contract.ManagedUser
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/users/"+url.PathEscape(name), nil, &response)
	return response, err
}

func (client *Client) CreateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error) {
	var response contract.ManagedUser
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/users", value, &response)
	return response, err
}

func (client *Client) UpdateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error) {
	var response contract.ManagedUser
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/users/"+url.PathEscape(value.Name), value, &response)
	return response, err
}

func (client *Client) DeleteUser(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/users/"+url.PathEscape(name), nil, nil)
}

func (client *Client) ListGroups(ctx context.Context) (contract.GroupList, error) {
	var response contract.GroupList
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/groups", nil, &response)
	return response, err
}

func (client *Client) GetGroup(ctx context.Context, name string) (contract.ManagedGroup, error) {
	var response contract.ManagedGroup
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/groups/"+url.PathEscape(name), nil, &response)
	return response, err
}

func (client *Client) CreateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error) {
	var response contract.ManagedGroup
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/groups", value, &response)
	return response, err
}

func (client *Client) UpdateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error) {
	var response contract.ManagedGroup
	// The ZigFS PATCH endpoint accepts GroupPatch fields only. In particular,
	// updated_at is a server-owned revision and must never be sent back as an
	// input field (the strict Zig JSON decoder rejects unknown fields).
	patch := struct {
		Name        string   `json:"name"`
		Description string   `json:"description"`
		Enabled     bool     `json:"enabled"`
		Policies    []string `json:"policies"`
		Members     []string `json:"members"`
		TagsJSON    string   `json:"tags_json,omitempty"`
	}{
		Name: value.Name, Description: value.Description, Enabled: value.Enabled,
		Policies: value.Policies, Members: value.Members, TagsJSON: value.TagsJSON,
	}
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/groups/"+url.PathEscape(value.Name), patch, &response)
	return response, err
}

func (client *Client) DeleteGroup(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/groups/"+url.PathEscape(name), nil, nil)
}

func userAccessKeysPath(name string) string {
	return "/_admin/v1/users/" + url.PathEscape(name) + "/access-keys"
}
func (client *Client) ListUserAccessKeys(ctx context.Context, name string) (contract.ListAccessKeysResponse, error) {
	var response contract.ListAccessKeysResponse
	err := client.requestJSON(ctx, http.MethodGet, userAccessKeysPath(name), nil, &response)
	return response, err
}
func (client *Client) CreateUserAccessKey(ctx context.Context, name string, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	var response contract.CreateAccessKeyResponse
	err := client.requestJSON(ctx, http.MethodPost, userAccessKeysPath(name), request, &response)
	return response, err
}
func (client *Client) UpdateUserAccessKey(ctx context.Context, name, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error) {
	var response contract.AccessKey
	err := client.requestJSON(ctx, http.MethodPatch, userAccessKeysPath(name)+"/"+url.PathEscape(id), request, &response)
	return response, err
}
func (client *Client) DeleteUserAccessKey(ctx context.Context, name, id string) error {
	return client.requestJSON(ctx, http.MethodDelete, userAccessKeysPath(name)+"/"+url.PathEscape(id), nil, nil)
}

func (client *Client) KMSSettings(ctx context.Context) (contract.KMSStatus, error) {
	var response contract.KMSStatus
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/settings/kms", nil, &response)
	return response, err
}
func (client *Client) SaveKMSSettings(ctx context.Context, config contract.KMSConfig) (contract.KMSStatus, error) {
	var response contract.KMSStatus
	err := client.requestJSON(ctx, http.MethodPut, "/_admin/v1/settings/kms", config, &response)
	return response, err
}

func (client *Client) StartKMS(ctx context.Context) (contract.KMSStatus, error) {
	var response contract.KMSStatus
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/settings/kms/start", nil, &response)
	return response, err
}

func (client *Client) StopKMS(ctx context.Context) (contract.KMSStatus, error) {
	var response contract.KMSStatus
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/settings/kms/stop", nil, &response)
	return response, err
}

func (client *Client) ClearKMSCache(ctx context.Context) (contract.KMSStatus, error) {
	var response contract.KMSStatus
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/settings/kms/clear-cache", nil, &response)
	return response, err
}

func (client *Client) KMSKeys(ctx context.Context, method string, action bool, input json.RawMessage) (json.RawMessage, error) {
	path := "/_admin/v1/settings/kms/keys"
	if action {
		path += "/action"
	}
	var response json.RawMessage
	var body any
	if len(input) > 0 {
		body = input
	}
	err := client.requestJSON(ctx, method, path, body, &response)
	return response, err
}

func (client *Client) LogSettings(ctx context.Context, method, operation string, input json.RawMessage) (json.RawMessage, error) {
	path := "/_admin/v1/settings/logs"
	if operation != "" {
		path += "/" + operation
	}
	var response json.RawMessage
	var body any
	if len(input) > 0 {
		body = input
	}
	err := client.requestJSON(ctx, method, path, body, &response)
	return response, err
}

func (client *Client) AuditLogSettings(ctx context.Context, method, operation string, input json.RawMessage) (json.RawMessage, error) {
	path := "/_admin/v1/settings/audit-logs"
	if operation != "" {
		path += "/" + operation
	}
	var response json.RawMessage
	var body any
	if len(input) > 0 {
		body = input
	}
	err := client.requestJSON(ctx, method, path, body, &response)
	return response, err
}

func (client *Client) Logout(ctx context.Context) error {
	return client.requestJSON(ctx, http.MethodPost, "/_admin/v1/auth/logout", nil, nil)
}

func (client *Client) AuditEvents(ctx context.Context, operation, query string) (json.RawMessage, error) {
	path := "/_admin/v1/audit-events"
	if operation == "options" {
		path += "/options"
	}
	if query != "" {
		path += "?" + query
	}
	var result json.RawMessage
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &result)
	return result, err
}

func (client *Client) SaveNetworkSettings(ctx context.Context, input json.RawMessage) (json.RawMessage, error) {
	var response json.RawMessage
	err := client.requestJSON(ctx, http.MethodPut, "/_admin/v1/settings/network", input, &response)
	return response, err
}

func (client *Client) SetEndpoints(values []string) {
	client.endpointMu.Lock()
	defer client.endpointMu.Unlock()
	client.candidates = append([]string(nil), values...)
	if len(values) > 0 {
		client.endpoint = values[0]
	}
}
func (client *Client) Endpoint() string {
	client.endpointMu.RLock()
	defer client.endpointMu.RUnlock()
	return client.endpoint
}
func dialFailure(err error) bool {
	var op *net.OpError
	return errors.As(err, &op) && op.Op == "dial"
}
func (client *Client) SaveListenerSettings(ctx context.Context, address string) error {
	return client.requestJSON(ctx, http.MethodPut, "/_admin/v1/settings/listener", map[string]string{"api_address": address}, nil)
}

func (client *Client) InstanceSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	var response json.RawMessage
	var body any
	if len(input) > 0 {
		body = input
	}
	err := client.requestJSON(ctx, method, "/_admin/v1/settings/instance", body, &response)
	return response, err
}

func (client *Client) RegionSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	var response json.RawMessage
	var body any
	if len(input) > 0 {
		body = input
	}
	err := client.requestJSON(ctx, method, "/_admin/v1/settings/region", body, &response)
	return response, err
}

func (client *Client) AuthenticationSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	var response json.RawMessage
	var body any
	if len(input) > 0 {
		body = input
	}
	err := client.requestJSON(ctx, method, "/_admin/v1/settings/authentication", body, &response)
	return response, err
}

func (client *Client) DisplaySettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	var response json.RawMessage
	var body any
	if len(input) > 0 {
		body = input
	}
	err := client.requestJSON(ctx, method, "/_admin/v1/settings/display", body, &response)
	return response, err
}
