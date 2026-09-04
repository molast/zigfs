package contract

import "time"

type Bucket struct {
	Name      string    `json:"name"`
	Owner     string    `json:"owner"`
	CreatedAt time.Time `json:"created_at"`
}

type ListBucketsResponse struct {
	Items []Bucket `json:"items"`
}

type CreateBucketRequest struct {
	Name  string `json:"name" binding:"required"`
	Owner string `json:"owner" binding:"required"`
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
	AccessKey     string `json:"access_key" binding:"required"`
	Bucket        string `json:"bucket" binding:"required"`
	Key           string `json:"key" binding:"required"`
	Method        string `json:"method" binding:"required"`
	ExpiresSecond int64  `json:"expires_seconds" binding:"required"`
}

type PresignObjectResponse struct {
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expires_at"`
}

type AccessKey struct {
	ID        string           `json:"id"`
	AccessKey string           `json:"access_key"`
	Owner     string           `json:"owner"`
	Enabled   bool             `json:"enabled"`
	Policy    CredentialPolicy `json:"policy"`
	CreatedAt time.Time        `json:"created_at"`
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
	Owner  string            `json:"owner" binding:"required"`
	Policy *CredentialPolicy `json:"policy,omitempty"`
}

type CreateAccessKeyResponse struct {
	AccessKey
	SecretKey string `json:"secret_key"`
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

type ManagementHealthResponse struct {
	Status   string   `json:"status"`
	Recovery string   `json:"recovery"`
	Reason   string   `json:"reason"`
	Actions  []string `json:"actions"`
}

type SettingsResponse struct {
	APIAddress             string `json:"api_address"`
	S3PublicEndpoint       string `json:"s3_public_endpoint"`
	S3Region               string `json:"s3_region"`
	RequestTimeSkewSeconds int64  `json:"request_time_skew_seconds"`
	MultipartExpirySeconds int64  `json:"multipart_expiry_seconds"`
	StreamBufferSize       int64  `json:"stream_buffer_size"`
	MetricsEnabled         bool   `json:"metrics_enabled"`
	MetricsAddress         string `json:"metrics_address"`
	AdminSessionTTLSeconds int64  `json:"admin_session_ttl_seconds"`
	ReloadRequired         bool   `json:"reload_required"`
}
