package contract

import "time"

type Bucket struct {
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type ListBucketsResponse struct {
	Items []Bucket `json:"items"`
}

type CreateBucketRequest struct {
	Name string `json:"name" binding:"required"`
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
	ID        string    `json:"id"`
	AccessKey string    `json:"access_key"`
	Enabled   bool      `json:"enabled"`
	CreatedAt time.Time `json:"created_at"`
}

type ListAccessKeysResponse struct {
	Items []AccessKey `json:"items"`
}

type CreateAccessKeyRequest struct {
	Name string `json:"name" binding:"required"`
}

type CreateAccessKeyResponse struct {
	AccessKey
	SecretKey string `json:"secret_key"`
}

type UpdateAccessKeyRequest struct {
	Enabled *bool `json:"enabled" binding:"required"`
}
