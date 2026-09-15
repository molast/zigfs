package handler

import (
	"context"
	"net/http"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
)

type ManagementService interface {
	ListBuckets(ctx context.Context) (contract.ListBucketsResponse, error)
	CreateBucket(ctx context.Context, request contract.CreateBucketRequest) (contract.Bucket, error)
	DeleteBucket(ctx context.Context, name string) error
	GetBucketConfiguration(ctx context.Context, name string) (contract.BucketConfiguration, error)
	UpdateBucketConfiguration(ctx context.Context, name string, request contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error)
	ListObjectVersions(ctx context.Context, bucket, prefix string) (contract.ListObjectVersionsResponse, error)
	ListObjects(ctx context.Context, bucket, prefix, cursor string) (contract.ListObjectsResponse, error)
	PresignObject(ctx context.Context, request contract.PresignObjectRequest) (contract.PresignObjectResponse, error)
	CreateMultipartUpload(ctx context.Context, request contract.CreateMultipartUploadRequest) (contract.MultipartUpload, error)
	ListMultipartUploads(ctx context.Context, bucket, prefix, keyMarker, uploadIDMarker string) (contract.ListMultipartUploadsResponse, error)
	GetMultipartUpload(ctx context.Context, uploadID, bucket, key string) (contract.MultipartUpload, error)
	CompleteMultipartUpload(ctx context.Context, uploadID string, request contract.CompleteMultipartUploadRequest) (contract.Object, error)
	AbortMultipartUpload(ctx context.Context, uploadID, bucket, key string) error
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
		ctx.Query("continuation_token"),
	)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
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
