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

func (service *Management) DeleteDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) error {
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
	return service.zig.Settings(ctx)
}
