package handler

import (
	"context"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
)

type ManagementService interface {
	ListGroups(ctx context.Context) (contract.GroupList, error)
	GetGroup(ctx context.Context, name string) (contract.ManagedGroup, error)
	CreateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error)
	UpdateGroup(ctx context.Context, value contract.ManagedGroup) (contract.ManagedGroup, error)
	DeleteGroup(ctx context.Context, name string) error

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
	GetBucketTags(ctx context.Context, name string) (contract.BucketTags, error)
	PutBucketTags(ctx context.Context, name string, tags contract.BucketTags) (contract.BucketTags, error)
	DeleteBucketTags(ctx context.Context, name string) error
	UpdateBucketConfiguration(ctx context.Context, name string, request contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error)
	ListObjectVersions(ctx context.Context, bucket, prefix string) (contract.ListObjectVersionsResponse, error)
	ListObjects(ctx context.Context, bucket, prefix, search, cursor, maxKeys, delimiter string) (contract.ListObjectsResponse, error)
	CreateDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) (contract.Directory, error)
	DeleteDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) error
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
	request := contract.CreateDirectoryRequest{Key: ctx.Query("key")}
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
