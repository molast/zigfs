package port

import (
	"context"
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
	Ready(ctx context.Context) error
	Login(ctx context.Context, request contract.LoginRequest) (contract.LoginResponse, error)
	Session(ctx context.Context) (contract.SessionResponse, error)
	System(ctx context.Context) (contract.SystemResponse, error)
	Storage(ctx context.Context) (contract.StorageResponse, error)
	StorageScanner(ctx context.Context) (contract.StorageScannerStatus, error)
	RunStorageGC(ctx context.Context) (contract.StorageScanReport, error)
	ManagementHealth(ctx context.Context) (contract.ManagementHealthResponse, error)
	Settings(ctx context.Context) (contract.SettingsResponse, error)
	ListBuckets(ctx context.Context) (contract.ListBucketsResponse, error)
	CreateBucket(ctx context.Context, request contract.CreateBucketRequest) (contract.Bucket, error)
	DeleteBucket(ctx context.Context, name string) error
	GetBucketConfiguration(ctx context.Context, name string) (contract.BucketConfiguration, error)
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
	ListAccessKeys(ctx context.Context) (contract.ListAccessKeysResponse, error)
	CreateAccessKey(ctx context.Context, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error)
	UpdateAccessKey(ctx context.Context, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error)
	DeleteAccessKey(ctx context.Context, id string) error
}
