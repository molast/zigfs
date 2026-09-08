package service

import (
	"context"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
)

type Management struct {
	zig port.ZigClient
}

func NewManagement(zig port.ZigClient) *Management {
	return &Management{zig: zig}
}

func (service *Management) ListBuckets(ctx context.Context) (contract.ListBucketsResponse, error) {
	return service.zig.ListBuckets(ctx)
}

func (service *Management) CreateBucket(ctx context.Context, request contract.CreateBucketRequest) (contract.Bucket, error) {
	return service.zig.CreateBucket(ctx, request)
}

func (service *Management) DeleteBucket(ctx context.Context, name string) error {
	return service.zig.DeleteBucket(ctx, name)
}

func (service *Management) ListObjects(ctx context.Context, bucket, prefix, cursor string) (contract.ListObjectsResponse, error) {
	return service.zig.ListObjects(ctx, bucket, prefix, cursor)
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

func (service *Management) Health(ctx context.Context) (contract.ManagementHealthResponse, error) {
	return service.zig.ManagementHealth(ctx)
}

func (service *Management) Settings(ctx context.Context) (contract.SettingsResponse, error) {
	return service.zig.Settings(ctx)
}
