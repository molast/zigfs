package port

import (
	"context"

	"zigfs-admin/server/internal/contract"
)

type ZigClient interface {
	Ready(ctx context.Context) error
	System(ctx context.Context) (contract.SystemResponse, error)
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
