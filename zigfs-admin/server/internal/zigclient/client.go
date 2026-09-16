package zigclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/port"
	"zigfs-admin/server/internal/requestid"
)

type Client struct {
	endpoint   string
	httpClient *http.Client
}

func New(endpoint string, timeout time.Duration) *Client {
	return &Client{
		endpoint:   endpoint,
		httpClient: &http.Client{Timeout: timeout},
	}
}

func (client *Client) Ready(ctx context.Context) error {
	return client.requestJSON(ctx, http.MethodGet, "/health/ready", nil, nil)
}

func (client *Client) Login(ctx context.Context, request contract.LoginRequest) (contract.LoginResponse, error) {
	var response contract.LoginResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/auth/login", request, &response)
	return response, err
}

func (client *Client) Session(ctx context.Context) (contract.SessionResponse, error) {
	var response contract.SessionResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/auth/session", nil, &response)
	return response, err
}

func (client *Client) System(ctx context.Context) (contract.SystemResponse, error) {
	var response contract.SystemResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/system", nil, &response)
	return response, err
}

func (client *Client) Storage(ctx context.Context) (contract.StorageResponse, error) {
	var response contract.StorageResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/storage", nil, &response)
	return response, err
}

func (client *Client) StorageScanner(ctx context.Context) (contract.StorageScannerStatus, error) {
	var response contract.StorageScannerStatus
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/storage/scanner", nil, &response)
	return response, err
}

func (client *Client) RunStorageGC(ctx context.Context) (contract.StorageScanReport, error) {
	var response contract.StorageScanReport
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/storage/gc", nil, &response)
	return response, err
}

func (client *Client) ManagementHealth(ctx context.Context) (contract.ManagementHealthResponse, error) {
	var response contract.ManagementHealthResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/health", nil, &response)
	return response, err
}

func (client *Client) Settings(ctx context.Context) (contract.SettingsResponse, error) {
	var response contract.SettingsResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/settings", nil, &response)
	return response, err
}

func (client *Client) ListBuckets(ctx context.Context) (contract.ListBucketsResponse, error) {
	var response contract.ListBucketsResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/buckets", nil, &response)
	return response, err
}

func (client *Client) CreateBucket(ctx context.Context, request contract.CreateBucketRequest) (contract.Bucket, error) {
	var response contract.Bucket
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/buckets", request, &response)
	return response, err
}

func (client *Client) DeleteBucket(ctx context.Context, name string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/buckets/"+url.PathEscape(name), nil, nil)
}

func (client *Client) GetBucketConfiguration(ctx context.Context, name string) (contract.BucketConfiguration, error) {
	var response contract.BucketConfiguration
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/buckets/"+url.PathEscape(name)+"/configuration", nil, &response)
	return response, err
}

func (client *Client) UpdateBucketConfiguration(ctx context.Context, name string, request contract.UpdateBucketConfigurationRequest) (contract.BucketConfiguration, error) {
	var response contract.BucketConfiguration
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/buckets/"+url.PathEscape(name)+"/configuration", request, &response)
	return response, err
}

func (client *Client) ListObjectVersions(ctx context.Context, bucket, prefix string) (contract.ListObjectVersionsResponse, error) {
	query := url.Values{}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(bucket) + "/versions"
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}
	var response contract.ListObjectVersionsResponse
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}

func (client *Client) ListObjects(ctx context.Context, bucket, prefix, search, cursor, maxKeys, delimiter string) (contract.ListObjectsResponse, error) {
	query := url.Values{}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	if search != "" {
		query.Set("search", search)
	}
	if cursor != "" {
		query.Set("continuation_token", cursor)
	}
	if maxKeys != "" {
		query.Set("max_keys", maxKeys)
	}
	if delimiter != "" {
		query.Set("delimiter", delimiter)
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(bucket) + "/objects"
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}

	var response contract.ListObjectsResponse
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}

func (client *Client) CreateDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) (contract.Directory, error) {
	var response contract.Directory
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/buckets/"+url.PathEscape(bucket)+"/directories", request, &response)
	return response, err
}

func (client *Client) DeleteDirectory(ctx context.Context, bucket string, request contract.CreateDirectoryRequest) error {
	query := url.Values{"key": {request.Key}}
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/buckets/"+url.PathEscape(bucket)+"/directories?"+query.Encode(), nil, nil)
}

func (client *Client) PresignObject(ctx context.Context, request contract.PresignObjectRequest) (contract.PresignObjectResponse, error) {
	var response contract.PresignObjectResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/objects/presign", request, &response)
	return response, err
}

func (client *Client) CreateMultipartUpload(ctx context.Context, request contract.CreateMultipartUploadRequest) (contract.MultipartUpload, error) {
	var response contract.MultipartUpload
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/multipart-uploads", request, &response)
	return response, err
}

func (client *Client) ListMultipartUploads(ctx context.Context, bucket, prefix, keyMarker, uploadIDMarker string) (contract.ListMultipartUploadsResponse, error) {
	query := url.Values{}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	if keyMarker != "" {
		query.Set("key_marker", keyMarker)
	}
	if uploadIDMarker != "" {
		query.Set("upload_id_marker", uploadIDMarker)
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(bucket) + "/multipart-uploads"
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}
	var response contract.ListMultipartUploadsResponse
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}

func (client *Client) GetMultipartUpload(ctx context.Context, uploadID, bucket, key string) (contract.MultipartUpload, error) {
	query := url.Values{"bucket": {bucket}, "key": {key}}
	var response contract.MultipartUpload
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/multipart-uploads/"+url.PathEscape(uploadID)+"?"+query.Encode(), nil, &response)
	return response, err
}

func (client *Client) CompleteMultipartUpload(ctx context.Context, uploadID string, request contract.CompleteMultipartUploadRequest) (contract.Object, error) {
	var response contract.Object
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/multipart-uploads/"+url.PathEscape(uploadID)+"/complete", request, &response)
	return response, err
}

func (client *Client) AbortMultipartUpload(ctx context.Context, uploadID, bucket, key string) error {
	query := url.Values{"bucket": {bucket}, "key": {key}}
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/multipart-uploads/"+url.PathEscape(uploadID)+"?"+query.Encode(), nil, nil)
}

func (client *Client) ListAccessKeys(ctx context.Context) (contract.ListAccessKeysResponse, error) {
	var response contract.ListAccessKeysResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/access-keys", nil, &response)
	return response, err
}

func (client *Client) CreateAccessKey(ctx context.Context, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	var response contract.CreateAccessKeyResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/access-keys", request, &response)
	return response, err
}

func (client *Client) UpdateAccessKey(ctx context.Context, id string, request contract.UpdateAccessKeyRequest) (contract.AccessKey, error) {
	var response contract.AccessKey
	err := client.requestJSON(ctx, http.MethodPatch, "/_admin/v1/access-keys/"+url.PathEscape(id), request, &response)
	return response, err
}

func (client *Client) DeleteAccessKey(ctx context.Context, id string) error {
	return client.requestJSON(ctx, http.MethodDelete, "/_admin/v1/access-keys/"+url.PathEscape(id), nil, nil)
}

func (client *Client) requestJSON(ctx context.Context, method, path string, body, target any) error {
	var payload *bytes.Reader
	if body == nil {
		payload = bytes.NewReader(nil)
	} else {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode zig request: %w", err)
		}
		payload = bytes.NewReader(encoded)
	}

	request, err := http.NewRequestWithContext(ctx, method, client.endpoint+path, payload)
	if err != nil {
		return fmt.Errorf("create zig request: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if token := managementauth.Token(ctx); token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if id := requestid.FromContext(ctx); id != "" {
		request.Header.Set("X-Request-ID", id)
	}

	response, err := client.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("call zig service: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		var upstream contract.ErrorResponse
		_ = json.NewDecoder(io.LimitReader(response.Body, 1024*1024)).Decode(&upstream)
		return &port.StatusError{
			StatusCode: response.StatusCode,
			Code:       upstream.Code,
			Message:    upstream.Message,
			RequestID:  upstream.RequestID,
		}
	}
	if target == nil || response.StatusCode == http.StatusNoContent {
		return nil
	}
	if err = json.NewDecoder(response.Body).Decode(target); err != nil {
		return fmt.Errorf("decode zig response: %w", err)
	}
	return nil
}
