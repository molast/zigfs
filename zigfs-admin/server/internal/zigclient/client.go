package zigclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/requestid"
)

type Client struct {
	endpoint   string
	adminToken string
	httpClient *http.Client
}

func New(endpoint, adminToken string, timeout time.Duration) *Client {
	return &Client{
		endpoint:   endpoint,
		adminToken: adminToken,
		httpClient: &http.Client{Timeout: timeout},
	}
}

func (client *Client) Ready(ctx context.Context) error {
	return client.requestJSON(ctx, http.MethodGet, "/health/ready", nil, nil)
}

func (client *Client) System(ctx context.Context) (contract.SystemResponse, error) {
	var response contract.SystemResponse
	err := client.requestJSON(ctx, http.MethodGet, "/_admin/v1/system", nil, &response)
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

func (client *Client) ListObjects(ctx context.Context, bucket, prefix, cursor string) (contract.ListObjectsResponse, error) {
	query := url.Values{}
	if prefix != "" {
		query.Set("prefix", prefix)
	}
	if cursor != "" {
		query.Set("continuation_token", cursor)
	}
	path := "/_admin/v1/buckets/" + url.PathEscape(bucket) + "/objects"
	if encoded := query.Encode(); encoded != "" {
		path += "?" + encoded
	}

	var response contract.ListObjectsResponse
	err := client.requestJSON(ctx, http.MethodGet, path, nil, &response)
	return response, err
}

func (client *Client) PresignObject(ctx context.Context, request contract.PresignObjectRequest) (contract.PresignObjectResponse, error) {
	var response contract.PresignObjectResponse
	err := client.requestJSON(ctx, http.MethodPost, "/_admin/v1/objects/presign", request, &response)
	return response, err
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
	if client.adminToken != "" {
		request.Header.Set("Authorization", "Bearer "+client.adminToken)
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
		return fmt.Errorf("zig service returned status %d", response.StatusCode)
	}
	if target == nil || response.StatusCode == http.StatusNoContent {
		return nil
	}
	if err = json.NewDecoder(response.Body).Decode(target); err != nil {
		return fmt.Errorf("decode zig response: %w", err)
	}
	return nil
}
