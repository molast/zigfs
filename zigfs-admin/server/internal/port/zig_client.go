package port

import (
	"context"
	"encoding/json"
	"fmt"

	"zigfs-admin/server/internal/contract"
)

type StatusError struct {
	StatusCode int
	Code       string
	Message    string
	RequestID  string
}

func (err *StatusError) Error() string {
	return fmt.Sprintf("ZigFS returned status %d", err.StatusCode)
}

type ZigClient interface {
	Logout(context.Context) error
	OIDCAuth(context.Context, string, string, json.RawMessage) (json.RawMessage, error)
	OIDCProviders(context.Context, string, string, json.RawMessage) (json.RawMessage, error)
	ListGroups(ctx context.Context) (contract.GroupList, error)
	GetGroup(ctx context.Context, name string) (contract.ManagedGroup, error)
	CreateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error)
	UpdateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error)
	DeleteGroup(ctx context.Context, name string) error

	ListOrganizations(ctx context.Context) (contract.OrganizationList, error)
	CreateOrganization(ctx context.Context, value contract.Organization) (contract.Organization, error)
	UpdateOrganization(ctx context.Context, value contract.Organization) (contract.Organization, error)
	DeleteOrganization(ctx context.Context, name string) error
	ListRoles(ctx context.Context) (contract.RoleList, error)
	CreateRole(ctx context.Context, value contract.Role) (contract.Role, error)
	UpdateRole(ctx context.Context, value contract.Role) (contract.Role, error)
	DeleteRole(ctx context.Context, name string) error
	AssumeRole(ctx context.Context, request contract.AssumeRoleRequest) (contract.AssumeRoleResponse, error)
	ListRoleSessions(ctx context.Context) (contract.RoleSessionList, error)
	RevokeRoleSession(ctx context.Context, accessKey string) error
	ListUsers(ctx context.Context) (contract.UserList, error)
	GetUser(ctx context.Context, name string) (contract.ManagedUser, error)
	CreateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error)
	UpdateUser(ctx context.Context, value contract.UserWrite) (contract.ManagedUser, error)
	DeleteUser(ctx context.Context, name string) error

	ListPolicies(ctx context.Context) (contract.PolicyList, error)
	GetPolicy(ctx context.Context, name string) (contract.ManagedPolicy, error)
	CreatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error)
	UpdatePolicy(ctx context.Context, policy contract.ManagedPolicy) (contract.ManagedPolicy, error)
	DeletePolicy(ctx context.Context, name string) error

	Ready(ctx context.Context) error
	Login(ctx context.Context, request contract.LoginRequest) (contract.LoginResponse, error)
	STSLogin(ctx context.Context, request contract.STSLoginRequest) (contract.LoginResponse, error)
	Session(ctx context.Context) (contract.SessionResponse, error)
	System(ctx context.Context) (contract.SystemResponse, error)
	Storage(ctx context.Context) (contract.StorageResponse, error)
	StorageScanner(ctx context.Context) (contract.StorageScannerStatus, error)
	RunStorageGC(ctx context.Context) (contract.StorageScanReport, error)
	ManagementHealth(ctx context.Context) (contract.ManagementHealthResponse, error)
	AuditEvents(context.Context, string, string) (json.RawMessage, error)
	LogSettings(context.Context, string, string, json.RawMessage) (json.RawMessage, error)
	AuditLogSettings(context.Context, string, string, json.RawMessage) (json.RawMessage, error)
	KMSSettings(ctx context.Context) (contract.KMSStatus, error)
	StartKMS(ctx context.Context) (contract.KMSStatus, error)
	KMSKeys(ctx context.Context, method string, action bool, input json.RawMessage) (json.RawMessage, error)
	ClearKMSCache(ctx context.Context) (contract.KMSStatus, error)
	StopKMS(ctx context.Context) (contract.KMSStatus, error)
	SaveKMSSettings(ctx context.Context, config contract.KMSConfig) (contract.KMSStatus, error)
	InstanceSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error)
	RegionSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error)
	DisplaySettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error)
	AuthenticationSettings(ctx context.Context, method string, input json.RawMessage) (json.RawMessage, error)
	Settings(ctx context.Context) (contract.SettingsResponse, error)
	SaveListenerSettings(ctx context.Context, address string) error
	SaveNetworkSettings(ctx context.Context, input json.RawMessage) (json.RawMessage, error)
	ListBuckets(ctx context.Context) (contract.ListBucketsResponse, error)
	CreateBucket(ctx context.Context, request contract.CreateBucketRequest) (contract.Bucket, error)
	DeleteBucket(ctx context.Context, name string) error
	GetBucketConfiguration(ctx context.Context, name string) (contract.BucketConfiguration, error)
	GetBucketUsage(ctx context.Context, name string) (contract.BucketUsage, error)
	ListBucketEvents(ctx context.Context, name, cursor, from, to, action, outcome string, limit int) (contract.ListBucketEventsResponse, error)
	GetBucketPolicy(ctx context.Context, name string) (contract.BucketPolicy, error)
	PutBucketPolicy(ctx context.Context, name string, policy contract.BucketPolicy) (contract.BucketPolicy, error)
	DeleteBucketPolicy(ctx context.Context, name string) error
	GetBucketTags(ctx context.Context, name string) (contract.BucketTags, error)
	PutBucketTags(ctx context.Context, name string, tags contract.BucketTags) (contract.BucketTags, error)
	DeleteBucketTags(ctx context.Context, name string) error
	UpdateBucketConfiguration(ctx context.Context, name string, request contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error)
	ListObjectVersions(ctx context.Context, bucket, prefix string) (contract.ListObjectVersionsResponse, error)
	ListObjects(ctx context.Context, bucket, prefix, search, cursor, maxKeys, delimiter string) (contract.ListObjectsResponse, error)
	CreateDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) (contract.Directory, error)
	DeleteDirectory(ctx context.Context, bucket string, request contract.DeleteDirectoryRequest) error
	PresignObject(ctx context.Context, request contract.PresignObjectRequest) (contract.PresignObjectResponse, error)
	CreateMultipartUpload(ctx context.Context, request contract.CreateMultipartUploadRequest) (contract.MultipartUpload, error)
	ListMultipartUploads(ctx context.Context, bucket, prefix, keyMarker, uploadIDMarker string) (contract.ListMultipartUploadsResponse, error)
	GetMultipartUpload(ctx context.Context, uploadID, bucket, key string) (contract.MultipartUpload, error)
	CompleteMultipartUpload(ctx context.Context, uploadID string, request contract.CompleteMultipartUploadRequest) (contract.Object, error)
	AbortMultipartUpload(ctx context.Context, uploadID, bucket, key string) error
	ListUserAccessKeys(ctx context.Context, name string) (contract.ListAccessKeysResponse, error)
	CreateUserAccessKey(ctx context.Context, name string, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error)
	UpdateUserAccessKey(ctx context.Context, name, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error)
	DeleteUserAccessKey(ctx context.Context, name, id string) error
	ListAccessKeys(ctx context.Context) (contract.ListAccessKeysResponse, error)
	CreateAccessKey(ctx context.Context, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error)
	UpdateAccessKey(ctx context.Context, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error)
	DeleteAccessKey(ctx context.Context, id string) error
}
