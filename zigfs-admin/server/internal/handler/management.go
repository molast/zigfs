package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
)

type ManagementService interface {
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
	Storage(ctx context.Context) (contract.StorageResponse, error)
	StorageScanner(ctx context.Context) (contract.StorageScannerStatus, error)
	RunStorageGC(ctx context.Context) (contract.StorageScanReport, error)
	Health(ctx context.Context) (contract.ManagementHealthResponse, error)
	AuditEvents(context.Context, string, string) (json.RawMessage, error)
	LogSettings(context.Context, string, string, json.RawMessage) (json.RawMessage, error)
	KMSSettings(ctx context.Context) (contract.KMSStatus, error)
	StartKMS(ctx context.Context) (contract.KMSStatus, error)
	KMSKeys(ctx context.Context, method string, action bool, input json.RawMessage) (json.RawMessage, error)
	ClearKMSCache(ctx context.Context) (contract.KMSStatus, error)
	StopKMS(ctx context.Context) (contract.KMSStatus, error)
	SaveKMSSettings(ctx context.Context, config contract.KMSConfig) (contract.KMSStatus, error)
	Settings(ctx context.Context) (contract.SettingsResponse, error)
}

type Management struct {
	service ManagementService
}

func NewManagement(service ManagementService) *Management {
	return &Management{service: service}
}

func (handler *Management) ListBuckets(ctx *gin.Context) {
	response, err := handler.service.ListBuckets(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreateBucket(ctx *gin.Context) {
	var request contract.CreateBucketRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.CreateBucket(ctx.Request.Context(), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) DeleteBucket(ctx *gin.Context) {
	if err := handler.service.DeleteBucket(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) GetBucketConfiguration(ctx *gin.Context) {
	response, err := handler.service.GetBucketConfiguration(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) GetBucketUsage(ctx *gin.Context) {
	response, err := handler.service.GetBucketUsage(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) ListBucketEvents(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	limit := 50
	if value := ctx.Query("limit"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil {
			writeError(ctx, http.StatusBadRequest, "InvalidQuery", "limit must be an integer")
			return
		}
		limit = parsed
	}
	response, err := handler.service.ListBucketEvents(ctx.Request.Context(), ctx.Param("name"), ctx.Query("cursor"), ctx.Query("from"), ctx.Query("to"), ctx.Query("action"), ctx.Query("outcome"), limit)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}
func (handler *Management) GetBucketPolicy(ctx *gin.Context) {
	response, err := handler.service.GetBucketPolicy(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}
func (handler *Management) PutBucketPolicy(ctx *gin.Context) {
	var request contract.BucketPolicy
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.PutBucketPolicy(ctx.Request.Context(), ctx.Param("name"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}
func (handler *Management) DeleteBucketPolicy(ctx *gin.Context) {
	if err := handler.service.DeleteBucketPolicy(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) GetBucketTags(ctx *gin.Context) {
	response, err := handler.service.GetBucketTags(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}
func (handler *Management) PutBucketTags(ctx *gin.Context) {
	var request contract.BucketTags
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.PutBucketTags(ctx.Request.Context(), ctx.Param("name"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}
func (handler *Management) DeleteBucketTags(ctx *gin.Context) {
	if err := handler.service.DeleteBucketTags(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) UpdateBucketConfiguration(ctx *gin.Context) {
	var request contract.UpdateBucketConfigurationRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.UpdateBucketConfiguration(ctx.Request.Context(), ctx.Param("name"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) ListObjectVersions(ctx *gin.Context) {
	response, err := handler.service.ListObjectVersions(ctx.Request.Context(), ctx.Param("name"), ctx.Query("prefix"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) ListObjects(ctx *gin.Context) {
	response, err := handler.service.ListObjects(
		ctx.Request.Context(),
		ctx.Param("name"),
		ctx.Query("prefix"),
		ctx.Query("search"),
		ctx.Query("continuation_token"),
		ctx.Query("max_keys"),
		ctx.Query("delimiter"),
	)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreateDirectory(ctx *gin.Context) {
	var request contract.CreateDirectoryRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.CreateDirectory(ctx.Request.Context(), ctx.Param("name"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) DeleteDirectory(ctx *gin.Context) {
	handler.deleteDirectory(ctx, false)
}

func (handler *Management) ForceCleanupDirectory(ctx *gin.Context) {
	handler.deleteDirectory(ctx, true)
}

func (handler *Management) deleteDirectory(ctx *gin.Context, force bool) {
	request := contract.DeleteDirectoryRequest{Key: ctx.Query("key")}
	if value, present := ctx.GetQuery("all_versions"); present {
		if value != "true" && value != "false" {
			writeError(ctx, http.StatusBadRequest, "InvalidRequest", "all_versions must be true or false")
			return
		}
		request.AllVersions = value == "true"
	}
	if request.Key == "" {
		if err := ctx.ShouldBindJSON(&request); err != nil {
			writeError(ctx, http.StatusBadRequest, "InvalidRequest", "directory key is required")
			return
		}
	}
	if request.Key == "" {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "directory key is required")
		return
	}
	request.ForceCleanup = force
	if err := handler.service.DeleteDirectory(ctx.Request.Context(), ctx.Param("name"), request); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) PresignObject(ctx *gin.Context) {
	var request contract.PresignObjectRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.PresignObject(ctx.Request.Context(), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreateMultipartUpload(ctx *gin.Context) {
	var request contract.CreateMultipartUploadRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.CreateMultipartUpload(ctx.Request.Context(), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) ListMultipartUploads(ctx *gin.Context) {
	response, err := handler.service.ListMultipartUploads(
		ctx.Request.Context(),
		ctx.Param("name"),
		ctx.Query("prefix"),
		ctx.Query("key_marker"),
		ctx.Query("upload_id_marker"),
	)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) GetMultipartUpload(ctx *gin.Context) {
	response, err := handler.service.GetMultipartUpload(
		ctx.Request.Context(),
		ctx.Param("id"),
		ctx.Query("bucket"),
		ctx.Query("key"),
	)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CompleteMultipartUpload(ctx *gin.Context) {
	var request contract.CompleteMultipartUploadRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.CompleteMultipartUpload(ctx.Request.Context(), ctx.Param("id"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) AbortMultipartUpload(ctx *gin.Context) {
	if ctx.Query("bucket") == "" || ctx.Query("key") == "" {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "bucket and key are required")
		return
	}
	if err := handler.service.AbortMultipartUpload(ctx.Request.Context(), ctx.Param("id"), ctx.Query("bucket"), ctx.Query("key")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) ListAccessKeys(ctx *gin.Context) {
	response, err := handler.service.ListAccessKeys(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreateAccessKey(ctx *gin.Context) {
	var request contract.CreateAccessKeyRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.CreateAccessKey(ctx.Request.Context(), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) UpdateAccessKey(ctx *gin.Context) {
	var request contract.UpdateAccessKeyRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.UpdateAccessKey(ctx.Request.Context(), ctx.Param("id"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) DeleteAccessKey(ctx *gin.Context) {
	if err := handler.service.DeleteAccessKey(ctx.Request.Context(), ctx.Param("id")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) Storage(ctx *gin.Context) {
	response, err := handler.service.Storage(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) StorageScanner(ctx *gin.Context) {
	response, err := handler.service.StorageScanner(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) RunStorageGC(ctx *gin.Context) {
	response, err := handler.service.RunStorageGC(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) Health(ctx *gin.Context) {
	response, err := handler.service.Health(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) Settings(ctx *gin.Context) {
	response, err := handler.service.Settings(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) ListPolicies(ctx *gin.Context) {
	response, err := handler.service.ListPolicies(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) GetPolicy(ctx *gin.Context) {
	response, err := handler.service.GetPolicy(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreatePolicy(ctx *gin.Context) {
	ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024)
	var policy contract.ManagedPolicy
	if err := ctx.ShouldBindJSON(&policy); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidPolicy", "invalid request")
		return
	}
	response, err := handler.service.CreatePolicy(ctx.Request.Context(), policy)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) UpdatePolicy(ctx *gin.Context) {
	ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024)
	var policy contract.ManagedPolicy
	if err := ctx.ShouldBindJSON(&policy); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidPolicy", "invalid request")
		return
	}
	if policy.Name != ctx.Param("name") {
		writeError(ctx, http.StatusBadRequest, "InvalidPolicy", "policy names cannot be changed")
		return
	}
	response, err := handler.service.UpdatePolicy(ctx.Request.Context(), policy)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) DeletePolicy(ctx *gin.Context) {
	if err := handler.service.DeletePolicy(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) ListOrganizations(ctx *gin.Context) {
	out, err := handler.service.ListOrganizations(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, out)
}
func (handler *Management) CreateOrganization(ctx *gin.Context) {
	var value contract.Organization
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "organization payload is invalid")
		return
	}
	out, err := handler.service.CreateOrganization(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, out)
}
func (handler *Management) DeleteOrganization(ctx *gin.Context) {
	if err := handler.service.DeleteOrganization(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}
func (handler *Management) UpdateOrganization(ctx *gin.Context) {
	var value contract.Organization
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "organization payload is invalid")
		return
	}
	value.Name = ctx.Param("name")
	out, err := handler.service.UpdateOrganization(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, out)
}
func (handler *Management) ListRoles(ctx *gin.Context) {
	out, err := handler.service.ListRoles(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, out)
}
func (handler *Management) CreateRole(ctx *gin.Context) {
	var value contract.Role
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "role payload is invalid")
		return
	}
	out, err := handler.service.CreateRole(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, out)
}
func (handler *Management) DeleteRole(ctx *gin.Context) {
	if err := handler.service.DeleteRole(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}
func (handler *Management) UpdateRole(ctx *gin.Context) {
	var value contract.Role
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "role payload is invalid")
		return
	}
	value.Name = ctx.Param("name")
	out, err := handler.service.UpdateRole(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, out)
}
func (handler *Management) AssumeRole(ctx *gin.Context) {
	var value contract.AssumeRoleRequest
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "assume role payload is invalid")
		return
	}
	out, err := handler.service.AssumeRole(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, out)
}
func (handler *Management) ListRoleSessions(ctx *gin.Context) {
	out, err := handler.service.ListRoleSessions(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, out)
}
func (handler *Management) RevokeRoleSession(ctx *gin.Context) {
	if err := handler.service.RevokeRoleSession(ctx.Request.Context(), ctx.Param("access_key")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) ListUsers(ctx *gin.Context) {
	response, err := handler.service.ListUsers(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) GetUser(ctx *gin.Context) {
	response, err := handler.service.GetUser(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreateUser(ctx *gin.Context) {
	ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024)
	var value contract.UserWrite
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidIdentity", "invalid request")
		return
	}
	if value.Password == nil || len(*value.Password) < 8 || len(*value.Password) > 1024 {
		writeError(ctx, http.StatusBadRequest, "InvalidPassword", "password must contain 8 to 1024 bytes")
		return
	}
	if value.Policies == nil {
		value.Policies = []string{}
	}
	response, err := handler.service.CreateUser(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) UpdateUser(ctx *gin.Context) {
	ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024)
	var value contract.UserWrite
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidIdentity", "invalid request")
		return
	}
	if value.Password != nil && (len(*value.Password) < 8 || len(*value.Password) > 1024) {
		writeError(ctx, http.StatusBadRequest, "InvalidPassword", "password must contain 8 to 1024 bytes")
		return
	}
	if value.Policies == nil {
		value.Policies = []string{}
	}
	if value.Name != ctx.Param("name") {
		writeError(ctx, http.StatusBadRequest, "InvalidIdentity", "names cannot be changed")
		return
	}
	response, err := handler.service.UpdateUser(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) DeleteUser(ctx *gin.Context) {
	if err := handler.service.DeleteUser(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) ListGroups(ctx *gin.Context) {
	response, err := handler.service.ListGroups(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) GetGroup(ctx *gin.Context) {
	response, err := handler.service.GetGroup(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreateGroup(ctx *gin.Context) {
	ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024)
	var value contract.ManagedGroup
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidIdentity", "invalid request")
		return
	}
	if value.Policies == nil {
		value.Policies = []string{}
	}
	if value.Members == nil {
		value.Members = []string{}
	}
	response, err := handler.service.CreateGroup(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) UpdateGroup(ctx *gin.Context) {
	ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024)
	var value contract.ManagedGroup
	if err := ctx.ShouldBindJSON(&value); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidIdentity", "invalid request")
		return
	}
	if value.Policies == nil {
		value.Policies = []string{}
	}
	if value.Members == nil {
		value.Members = []string{}
	}
	if value.Name != ctx.Param("name") {
		writeError(ctx, http.StatusBadRequest, "InvalidIdentity", "names cannot be changed")
		return
	}
	response, err := handler.service.UpdateGroup(ctx.Request.Context(), value)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) DeleteGroup(ctx *gin.Context) {
	if err := handler.service.DeleteGroup(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) ListUserAccessKeys(ctx *gin.Context) {
	response, err := handler.service.ListUserAccessKeys(ctx.Request.Context(), ctx.Param("name"))
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) CreateUserAccessKey(ctx *gin.Context) {
	var request contract.CreateAccessKeyRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.CreateUserAccessKey(ctx.Request.Context(), ctx.Param("name"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) UpdateUserAccessKey(ctx *gin.Context) {
	var request contract.UpdateAccessKeyRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.UpdateUserAccessKey(ctx.Request.Context(), ctx.Param("name"), ctx.Param("id"), request)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) DeleteUserAccessKey(ctx *gin.Context) {
	if err := handler.service.DeleteUserAccessKey(ctx.Request.Context(), ctx.Param("name"), ctx.Param("id")); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) KMSSettings(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	response, err := handler.service.KMSSettings(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}
func (handler *Management) SaveKMSSettings(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	var config contract.KMSConfig
	if err := ctx.ShouldBindJSON(&config); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
		return
	}
	response, err := handler.service.SaveKMSSettings(ctx.Request.Context(), config)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) StartKMS(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	response, err := handler.service.StartKMS(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) StopKMS(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	response, err := handler.service.StopKMS(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) ClearKMSCache(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	response, err := handler.service.ClearKMSCache(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) KMSKeys(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	action := strings.HasSuffix(ctx.FullPath(), "/action")
	var input json.RawMessage
	if ctx.Request.Method == http.MethodPost {
		if err := ctx.ShouldBindJSON(&input); err != nil {
			writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
			return
		}
	}
	response, err := handler.service.KMSKeys(ctx.Request.Context(), ctx.Request.Method, action, input)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	status := http.StatusOK
	if ctx.Request.Method == http.MethodPost && !action {
		status = http.StatusCreated
	}
	ctx.Data(status, "application/json", response)
}

func (handler *Management) LogSettings(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	operation := ""
	if strings.HasSuffix(ctx.FullPath(), "/query") {
		operation = "query"
	}
	if strings.HasSuffix(ctx.FullPath(), "/download") {
		operation = "download"
	}
	var input json.RawMessage
	if ctx.Request.Method == http.MethodPut {
		if err := ctx.ShouldBindJSON(&input); err != nil {
			writeError(ctx, http.StatusBadRequest, "InvalidRequest", "request body is invalid")
			return
		}
	}
	response, err := handler.service.LogSettings(ctx.Request.Context(), ctx.Request.Method, operation, input)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Data(http.StatusOK, "application/json", response)
}

func (handler *Management) AuditEvents(ctx *gin.Context) {
	operation := ""
	if strings.HasSuffix(ctx.Request.URL.Path, "/options") {
		operation = "options"
	}
	result, err := handler.service.AuditEvents(ctx.Request.Context(), operation, ctx.Request.URL.RawQuery)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Header("Cache-Control", "no-store")
	ctx.Data(http.StatusOK, "application/json", result)
}
