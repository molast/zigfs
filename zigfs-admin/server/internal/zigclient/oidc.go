package zigclient

import (
	"context"
	"encoding/json"
	"net/url"
)

func (client *Client) OIDCProviders(ctx context.Context, method, id string, body json.RawMessage) (json.RawMessage, error) {
	path := "/_admin/v1/oidc/providers"
	if id == "@validate" {
		path = "/_admin/v1/oidc/validate"
		id = ""
	}
	if id != "" {
		path += "/" + url.PathEscape(id)
	}
	var response json.RawMessage
	var payload any
	if len(body) != 0 {
		payload = body
	}
	err := client.requestJSON(ctx, method, path, payload, &response)
	return response, err
}

func (client *Client) OIDCAuth(ctx context.Context, method, operation string, body json.RawMessage) (json.RawMessage, error) {
	var response json.RawMessage
	var payload any
	if len(body) != 0 {
		payload = body
	}
	err := client.requestJSON(ctx, method, "/_admin/v1/auth/oidc/"+url.PathEscape(operation), payload, &response)
	return response, err
}
