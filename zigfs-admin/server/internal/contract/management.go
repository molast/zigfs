package contract

import "time"

type Bucket struct {
	Name             string    `json:"name"`
	Owner            string    `json:"owner"`
	CreatedAt        time.Time `json:"created_at"`
	Versioning       string    `json:"versioning"`
	LifecycleEnabled bool      `json:"lifecycle_enabled"`
}

type BucketConfiguration struct {
	Name                   string `json:"name"`
	Versioning             string `json:"versioning"`
	LifecycleConfiguration string `json:"lifecycle_configuration,omitempty"`
}

type UpdateBucketConfigurationRequest struct {
	Versioning             string `json:"versioning,omitempty"`
	LifecycleConfiguration string `json:"lifecycle_configuration,omitempty"`
	ClearLifecycle         bool   `json:"clear_lifecycle,omitempty"`
}

type ObjectVersion struct {
	Key            string    `json:"key"`
	VersionID      string    `json:"version_id"`
	IsLatest       bool      `json:"is_latest"`
	IsDeleteMarker bool      `json:"is_delete_marker"`
	Size           int64     `json:"size"`
	LastModified   time.Time `json:"last_modified"`
}

type ListObjectVersionsResponse struct {
	Items []ObjectVersion `json:"items"`
}

type ListBucketsResponse struct {
	Items []Bucket `json:"items"`
}

type CreateBucketRequest struct {
	Name  string `json:"name" binding:"required"`
	Owner string `json:"owner,omitempty"`
}

type Object struct {
	Key          string    `json:"key"`
	Size         int64     `json:"size"`
	ETag         string    `json:"etag"`
	LastModified time.Time `json:"last_modified"`
}

type ListObjectsResponse struct {
	Items             []Object `json:"items"`
	ContinuationToken string   `json:"continuation_token,omitempty"`
}

type PresignObjectRequest struct {
	AccessKey           string `json:"access_key" binding:"required"`
	Bucket              string `json:"bucket" binding:"required"`
	Key                 string `json:"key" binding:"required"`
	Method              string `json:"method" binding:"required"`
	ExpiresSecond       int64  `json:"expires_seconds" binding:"required"`
	UploadID            string `json:"upload_id,omitempty"`
	PartNumber          int    `json:"part_number,omitempty" binding:"omitempty,min=1,max=10000"`
	VersionID           string `json:"version_id,omitempty"`
	CopySourceBucket    string `json:"copy_source_bucket,omitempty"`
	CopySourceKey       string `json:"copy_source_key,omitempty"`
	CopySourceVersionID string `json:"copy_source_version_id,omitempty"`
}

type PresignObjectResponse struct {
	URL             string            `json:"url"`
	ExpiresAt       time.Time         `json:"expires_at"`
	RequiredHeaders map[string]string `json:"required_headers"`
}

type MultipartUploadSummary struct {
	UploadID    string    `json:"upload_id"`
	Bucket      string    `json:"bucket"`
	Key         string    `json:"key"`
	InitiatedAt time.Time `json:"initiated_at"`
}

type MultipartPart struct {
	PartNumber   int       `json:"part_number"`
	Size         int64     `json:"size"`
	ETag         string    `json:"etag"`
	LastModified time.Time `json:"last_modified"`
}

type MultipartUpload struct {
	MultipartUploadSummary
	ContentType   string          `json:"content_type"`
	Parts         []MultipartPart `json:"parts"`
	UploadedBytes int64           `json:"uploaded_bytes"`
}

type ListMultipartUploadsResponse struct {
	Items              []MultipartUploadSummary `json:"items"`
	IsTruncated        bool                     `json:"is_truncated"`
	NextKeyMarker      string                   `json:"next_key_marker,omitempty"`
	NextUploadIDMarker string                   `json:"next_upload_id_marker,omitempty"`
}

type CreateMultipartUploadRequest struct {
	Bucket      string `json:"bucket" binding:"required"`
	Key         string `json:"key" binding:"required"`
	ContentType string `json:"content_type" binding:"required"`
}

type CompleteMultipartPartRequest struct {
	PartNumber int    `json:"part_number" binding:"required,min=1,max=10000"`
	ETag       string `json:"etag" binding:"required"`
}

type CompleteMultipartUploadRequest struct {
	Bucket string                         `json:"bucket" binding:"required"`
	Key    string                         `json:"key" binding:"required"`
	Parts  []CompleteMultipartPartRequest `json:"parts" binding:"required,min=1,max=10000,dive"`
}

type AccessKey struct {
	ID           string           `json:"id"`
	AccessKey    string           `json:"access_key"`
	SecretKey    string           `json:"secret_key"`
	SessionToken string           `json:"session_token,omitempty"`
	Kind         string           `json:"kind"`
	Owner        string           `json:"owner"`
	Enabled      bool             `json:"enabled"`
	Policy       CredentialPolicy `json:"policy"`
	CreatedAt    time.Time        `json:"created_at"`
	ExpiresAt    *time.Time       `json:"expires_at,omitempty"`
}

type CredentialPolicy struct {
	BucketRead  bool `json:"bucket_read"`
	BucketWrite bool `json:"bucket_write"`
	ObjectRead  bool `json:"object_read"`
	ObjectWrite bool `json:"object_write"`
}

type ListAccessKeysResponse struct {
	Items []AccessKey `json:"items"`
}

type CreateAccessKeyRequest struct {
	Owner      string            `json:"owner,omitempty"`
	Policy     *CredentialPolicy `json:"policy,omitempty"`
	TTLSeconds *int64            `json:"ttl_seconds,omitempty" binding:"omitempty,min=60,max=43200"`
}

type CreateAccessKeyResponse struct {
	AccessKey
}

type UpdateAccessKeyRequest struct {
	Enabled *bool `json:"enabled" binding:"required"`
}

type StorageResponse struct {
	Measurement string `json:"measurement"`
	Total       *int64 `json:"total"`
	Used        int64  `json:"used"`
	Available   *int64 `json:"available"`
}

type StorageScanReport struct {
	Partition               *int  `json:"partition"`
	Partitions              int   `json:"partitions"`
	ScannedGenerations      int   `json:"scanned_generations"`
	RetainedGenerations     int   `json:"retained_generations"`
	RemovedGenerations      int   `json:"removed_generations"`
	ScannedBytes            int64 `json:"scanned_bytes"`
	RetainedBytes           int64 `json:"retained_bytes"`
	RemovedBytes            int64 `json:"removed_bytes"`
	ExpiredMultipartUploads int   `json:"expired_multipart_uploads"`
}

type StorageScannerStatus struct {
	Partitions    int                `json:"partitions"`
	NextPartition int                `json:"next_partition"`
	LastScan      *StorageScanReport `json:"last_scan"`
}

type ManagementHealthResponse struct {
	Status   string   `json:"status"`
	Recovery string   `json:"recovery"`
	Reason   string   `json:"reason"`
	Actions  []string `json:"actions"`
}

type SettingsResponse struct {
	APIAddress                   string `json:"api_address"`
	S3PublicEndpoint             string `json:"s3_public_endpoint"`
	S3VirtualHostedStyle         bool   `json:"s3_virtual_hosted_style"`
	S3Region                     string `json:"s3_region"`
	RequestTimeSkewSeconds       int64  `json:"request_time_skew_seconds"`
	MultipartExpirySeconds       int64  `json:"multipart_expiry_seconds"`
	LifecycleScanIntervalSeconds int64  `json:"lifecycle_scan_interval_seconds"`
	StreamBufferSize             int64  `json:"stream_buffer_size"`
	MetricsEnabled               bool   `json:"metrics_enabled"`
	MetricsAddress               string `json:"metrics_address"`
	AdminSessionTTLSeconds       int64  `json:"admin_session_ttl_seconds"`
	ReloadRequired               bool   `json:"reload_required"`
}
