package service

import (
	"context"
	"encoding/json"
	"sync"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
)

type Management struct {
	listenerMu         sync.Mutex
	ListenerFile       string
	SetEndpoints       func([]string)
	Endpoint           func() string
	AdminListenAddress string
	zig                port.ZigClient
}

func NewManagement(zig port.ZigClient) *Management {
	return &Management{zig: zig}
}

func (service *Management) ListBuckets(ctx context.Context) (contract.ListBucketsResponse, error) {
	return service.zig.ListBuckets(ctx)
}

func (service *Management) CreateBucket(ctx context.Context, request contract.CreateBucketRequest) (contract.Bucket, error) {
	// Bucket ownership is derived by ZigFS from the authenticated management
	// session. Do not allow the browser to switch tenants.
	request.Owner = ""
	return service.zig.CreateBucket(ctx, request)
}

func (service *Management) DeleteBucket(ctx context.Context, name string) error {
	return service.zig.DeleteBucket(ctx, name)
}

func (service *Management) GetBucketConfiguration(ctx context.Context, name string) (contract.BucketConfiguration, error) {
	return service.zig.GetBucketConfiguration(ctx, name)
}

func (service *Management) GetBucketUsage(ctx context.Context, name string) (contract.BucketUsage, error) {
	return service.zig.GetBucketUsage(ctx, name)
}

func (service *Management) ListBucketEvents(ctx context.Context, name, cursor, from, to, action, outcome string, limit int) (contract.ListBucketEventsResponse, error) {
	return service.zig.ListBucketEvents(ctx, name, cursor, from, to, action, outcome, limit)
}
func (service *Management) GetBucketPolicy(ctx context.Context, name string) (contract.BucketPolicy, error) {
	return service.zig.GetBucketPolicy(ctx, name)
}
func (service *Management) PutBucketPolicy(ctx context.Context, name string, tags contract.BucketPolicy) (contract.BucketPolicy, error) {
	return service.zig.PutBucketPolicy(ctx, name, tags)
}
func (service *Management) DeleteBucketPolicy(ctx context.Context, name string) error {
	return service.zig.DeleteBucketPolicy(ctx, name)
}

func (service *Management) GetBucketTags(ctx context.Context, name string) (contract.BucketTags, error) {
	return service.zig.GetBucketTags(ctx, name)
}
func (service *Management) PutBucketTags(ctx context.Context, name string, tags contract.BucketTags) (contract.BucketTags, error) {
	return service.zig.PutBucketTags(ctx, name, tags)
}
func (service *Management) DeleteBucketTags(ctx context.Context, name string) error {
	return service.zig.DeleteBucketTags(ctx, name)
}

func (service *Management) UpdateBucketConfiguration(ctx context.Context, name string, request contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error) {
	return service.zig.UpdateBucketConfiguration(ctx, name, request)
}

func (service *Management) ListObjectVersions(ctx context.Context, bucket, prefix string) (contract.ListObjectVersionsResponse, error) {
	return service.zig.ListObjectVersions(ctx, bucket, prefix)
}

func (service *Management) ListObjects(ctx context.Context, bucket, prefix, search, cursor, maxKeys, delimiter string) (contract.ListObjectsResponse, error) {
	return service.zig.ListObjects(ctx, bucket, prefix, search, cursor, maxKeys, delimiter)
}

func (service *Management) CreateDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) (contract.Directory, error) {
	return service.zig.CreateDirectory(ctx, bucket, request)
}

func (service *Management) DeleteDirectory(ctx context.Context, bucket string, request contract.DeleteDirectoryRequest) error {
	return service.zig.DeleteDirectory(ctx, bucket, request)
}

func (service *Management) PresignObject(ctx context.Context, request contract.PresignObjectRequest) (contract.PresignObjectResponse, error) {
	return service.zig.PresignObject(ctx, request)
}

func (service *Management) CreateMultipartUpload(ctx context.Context, request contract.CreateMultipartUploadRequest) (contract.MultipartUpload, error) {
	return service.zig.CreateMultipartUpload(ctx, request)
}

func (service *Management) ListMultipartUploads(ctx context.Context, bucket, prefix, keyMarker, uploadIDMarker string) (contract.ListMultipartUploadsResponse, error) {
	return service.zig.ListMultipartUploads(ctx, bucket, prefix, keyMarker, uploadIDMarker)
}

func (service *Management) GetMultipartUpload(ctx context.Context, uploadID, bucket, key string) (contract.MultipartUpload, error) {
	return service.zig.GetMultipartUpload(ctx, uploadID, bucket, key)
}

func (service *Management) CompleteMultipartUpload(ctx context.Context, uploadID string, request contract.CompleteMultipartUploadRequest) (contract.Object, error) {
	return service.zig.CompleteMultipartUpload(ctx, uploadID, request)
}

func (service *Management) AbortMultipartUpload(ctx context.Context, uploadID, bucket, key string) error {
	return service.zig.AbortMultipartUpload(ctx, uploadID, bucket, key)
}

func (service *Management) ListAccessKeys(ctx context.Context) (contract.ListAccessKeysResponse, error) {
	return service.zig.ListAccessKeys(ctx)
}

func (service *Management) CreateAccessKey(ctx context.Context, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	// Owner is assigned by ZigFS from the authenticated Management session.
	// Discard any browser-supplied value so the BFF cannot be used to switch tenants.
	request.Owner = ""
	return service.zig.CreateAccessKey(ctx, request)
}

func (service *Management) UpdateAccessKey(ctx context.Context, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error) {
	return service.zig.UpdateAccessKey(ctx, id, request)
}

func (service *Management) DeleteAccessKey(ctx context.Context, id string) error {
	return service.zig.DeleteAccessKey(ctx, id)
}

func (service *Management) Storage(ctx context.Context) (contract.StorageResponse, error) {
	return service.zig.Storage(ctx)
}

func (service *Management) StorageScanner(ctx context.Context) (contract.StorageScannerStatus, error) {
	return service.zig.StorageScanner(ctx)
}

func (service *Management) RunStorageGC(ctx context.Context) (contract.StorageScanReport, error) {
	return service.zig.RunStorageGC(ctx)
}

func (service *Management) Health(ctx context.Context) (contract.ManagementHealthResponse, error) {
	return service.zig.ManagementHealth(ctx)
}

func (service *Management) Settings(ctx context.Context) (contract.SettingsResponse, error) {
	response, err := service.zig.Settings(ctx)
	response.AdminListenAddress = service.AdminListenAddress
	service.listenerMu.Lock()
	defer service.listenerMu.Unlock()
	service.addListenerStatus(&response)
	return response, err
}

func (service *Management) ListPolicies(ctx context.Context) (contract.PolicyList, error) {
	return service.zig.ListPolicies(ctx)
}

func (service *Management) GetPolicy(ctx context.Context, name string) (contract.ManagedPolicy, error) {
	return service.zig.GetPolicy(ctx, name)
}

func (service *Management) CreatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error) {
	return service.zig.CreatePolicy(ctx, policy)
}

func (service *Management) UpdatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error) {
	return service.zig.UpdatePolicy(ctx, policy)
}

func (service *Management) DeletePolicy(ctx context.Context, name string) error {
	return service.zig.DeletePolicy(ctx, name)
}

func (service *Management) ListOrganizations(ctx context.Context) (contract.OrganizationList, error) {
	return service.zig.ListOrganizations(ctx)
}
func (service *Management) CreateOrganization(ctx context.Context, value contract.Organization) (contract.Organization, error) {
	return service.zig.CreateOrganization(ctx, value)
}
func (service *Management) UpdateOrganization(ctx context.Context, value contract.Organization) (contract.Organization, error) {
	return service.zig.UpdateOrganization(ctx, value)
}
func (service *Management) DeleteOrganization(ctx context.Context, name string) error {
	return service.zig.DeleteOrganization(ctx, name)
}
func (service *Management) ListRoles(ctx context.Context) (contract.RoleList, error) {
	return service.zig.ListRoles(ctx)
}
func (service *Management) CreateRole(ctx context.Context, value contract.Role) (contract.Role, error) {
	return service.zig.CreateRole(ctx, value)
}
func (service *Management) UpdateRole(ctx context.Context, value contract.Role) (contract.Role, error) {
	return service.zig.UpdateRole(ctx, value)
}
func (service *Management) DeleteRole(ctx context.Context, name string) error {
	return service.zig.DeleteRole(ctx, name)
}
func (service *Management) AssumeRole(ctx context.Context, request contract.AssumeRoleRequest) (contract.AssumeRoleResponse, error) {
	return service.zig.AssumeRole(ctx, request)
}
func (service *Management) ListRoleSessions(ctx context.Context) (contract.RoleSessionList, error) {
	return service.zig.ListRoleSessions(ctx)
}
func (service *Management) RevokeRoleSession(ctx context.Context, accessKey string) error {
	return service.zig.RevokeRoleSession(ctx, accessKey)
}

func (service *Management) ListUsers(ctx context.Context) (contract.UserList, error) {
	return service.zig.ListUsers(ctx)
}

func (service *Management) GetUser(ctx context.Context, name string) (contract.ManagedUser, error) {
	return service.zig.GetUser(ctx, name)
}

func (service *Management) CreateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error) {
	return service.zig.CreateUser(ctx, value)
}

func (service *Management) UpdateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error) {
	return service.zig.UpdateUser(ctx, value)
}

func (service *Management) DeleteUser(ctx context.Context, name string) error {
	return service.zig.DeleteUser(ctx, name)
}

func (service *Management) ListGroups(ctx context.Context) (contract.GroupList, error) {
	return service.zig.ListGroups(ctx)
}

func (service *Management) GetGroup(ctx context.Context, name string) (contract.ManagedGroup, error) {
	return service.zig.GetGroup(ctx, name)
}

func (service *Management) CreateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error) {
	return service.zig.CreateGroup(ctx, value)
}

func (service *Management) UpdateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error) {
	return service.zig.UpdateGroup(ctx, value)
}

func (service *Management) DeleteGroup(ctx context.Context, name string) error {
	return service.zig.DeleteGroup(ctx, name)
}

func (service *Management) ListUserAccessKeys(ctx context.Context, name string) (contract.ListAccessKeysResponse, error) {
	return service.zig.ListUserAccessKeys(ctx, name)
}
func (service *Management) CreateUserAccessKey(ctx context.Context, name string, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	request.Owner = ""
	return service.zig.CreateUserAccessKey(ctx, name, request)
}
func (service *Management) UpdateUserAccessKey(ctx context.Context, name, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error) {
	return service.zig.UpdateUserAccessKey(ctx, name, id, request)
}
func (service *Management) DeleteUserAccessKey(ctx context.Context, name, id string) error {
	return service.zig.DeleteUserAccessKey(ctx, name, id)
}

func (service *Management) KMSSettings(ctx context.Context) (contract.KMSStatus, error) {
	return service.zig.KMSSettings(ctx)
}
func (service *Management) SaveKMSSettings(ctx context.Context, config contract.KMSConfig) (contract.KMSStatus, error) {
	return service.zig.SaveKMSSettings(ctx, config)
}

func (service *Management) StartKMS(ctx context.Context) (contract.KMSStatus, error) {
	return service.zig.StartKMS(ctx)
}

func (service *Management) StopKMS(ctx context.Context) (contract.KMSStatus, error) {
	return service.zig.StopKMS(ctx)
}

func (service *Management) ClearKMSCache(ctx context.Context) (contract.KMSStatus, error) {
	return service.zig.ClearKMSCache(ctx)
}

func (service *Management) KMSKeys(ctx context.Context, method string, action bool, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.KMSKeys(ctx, method, action, input)
}

func (service *Management) AuditLogSettings(ctx context.Context, method, operation string, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.AuditLogSettings(ctx, method, operation, input)
}

func (service *Management) LogSettings(ctx context.Context, method, operation string, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.LogSettings(ctx, method, operation, input)
}

func (service *Management) AuditEvents(ctx context.Context, operation, query string) (json.RawMessage, error) {
	return service.zig.AuditEvents(ctx, operation, query)
}

func (service *Management) SaveNetworkSettings(ctx context.Context, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.SaveNetworkSettings(ctx, input)
}

func (service *Management) InstanceSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.InstanceSettings(ctx, method, input)
}

func (service *Management) RegionSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.RegionSettings(ctx, method, input)
}

func (service *Management) AuthenticationSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.AuthenticationSettings(ctx, method, input)
}

func (service *Management) DisplaySettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error) {
	return service.zig.DisplaySettings(ctx, method, input)
}
