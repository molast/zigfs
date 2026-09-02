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
	ListObjects(ctx context.Context, bucket, prefix, cursor string) (contract.ListObjectsResponse, error)
	PresignObject(ctx context.Context, request contract.PresignObjectRequest) (contract.PresignObjectResponse, error)
	ListAccessKeys(ctx context.Context) (contract.ListAccessKeysResponse, error)
	CreateAccessKey(ctx context.Context, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error)
	UpdateAccessKey(ctx context.Context, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error)
	DeleteAccessKey(ctx context.Context, id string) error
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
		writeStorageError(ctx)
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
		writeStorageError(ctx)
		return
	}
	ctx.JSON(http.StatusCreated, response)
}

func (handler *Management) DeleteBucket(ctx *gin.Context) {
	if err := handler.service.DeleteBucket(ctx.Request.Context(), ctx.Param("name")); err != nil {
		writeStorageError(ctx)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func (handler *Management) ListObjects(ctx *gin.Context) {
	response, err := handler.service.ListObjects(
		ctx.Request.Context(),
		ctx.Param("name"),
		ctx.Query("prefix"),
		ctx.Query("continuation_token"),
	)
	if err != nil {
		writeStorageError(ctx)
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
		writeStorageError(ctx)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) ListAccessKeys(ctx *gin.Context) {
	response, err := handler.service.ListAccessKeys(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx)
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
		writeStorageError(ctx)
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
		writeStorageError(ctx)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func (handler *Management) DeleteAccessKey(ctx *gin.Context) {
	if err := handler.service.DeleteAccessKey(ctx.Request.Context(), ctx.Param("id")); err != nil {
		writeStorageError(ctx)
		return
	}
	ctx.Status(http.StatusNoContent)
}

func writeStorageError(ctx *gin.Context) {
	writeError(ctx, http.StatusBadGateway, "StorageUnavailable", "storage service request failed")
}
