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
