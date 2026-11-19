package handler

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/molast/zigfs/pkg/gateway"
	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
)

type gatewayService struct {
	ManagementService
	denied bool
}

func (s gatewayService) Settings(context.Context) (contract.SettingsResponse, error) {
	if s.denied {
		return contract.SettingsResponse{}, &port.StatusError{StatusCode: 403, Code: "AccessDenied", Message: "denied"}
	}
	return contract.SettingsResponse{}, nil
}

func TestGatewayRequiresUpstreamAuthorizationBeforeReadingState(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewManagement(gatewayService{denied: true})
	h.Gateway = gateway.New(t.TempDir(), func() string { return "http://localhost:9000" })
	for _, path := range []string{"/api/v1/settings/gateway", "/api/v1/settings/gateway/ca.crt", "/api/v1/settings/gateway/local-setup.sh", "/api/v1/settings/gateway/local-setup.ps1"} {
		w := httptest.NewRecorder()
		ctx, _ := gin.CreateTestContext(w)
		ctx.Request = httptest.NewRequest("GET", path, nil)
		h.GatewaySettings(ctx)
		if w.Code != 403 {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body.String())
		}
	}
}

func TestGatewayMutationsRejectCrossOriginAndMissingOrigin(t *testing.T) {
	h := NewManagement(gatewayService{})
	h.Gateway = gateway.New(t.TempDir(), func() string { return "http://localhost:9000" })
	for _, origin := range []string{"", "https://attacker.test"} {
		w := httptest.NewRecorder()
		ctx, _ := gin.CreateTestContext(w)
		ctx.Request = httptest.NewRequest("PUT", "https://admin.test/api/v1/settings/gateway", strings.NewReader(`{}`))
		ctx.Request.Header.Set("Origin", origin)
		ctx.Request.Header.Set("Content-Type", "application/json")
		h.GatewaySettings(ctx)
		if w.Code != 403 {
			t.Fatalf("accepted origin %q: %d", origin, w.Code)
		}
	}
}

func TestGatewayAuditRejectionPreventsLocalMutation(t *testing.T) {
	h := NewManagement(gatewayService{})
	h.Gateway = gateway.New(t.TempDir(), func() string { return "http://localhost:9000" })
	calls := 0
	h.GatewayAudit = func(context.Context, string, string) error {
		calls++
		return errors.New("audit offline")
	}
	w := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(w)
	ctx.Request = httptest.NewRequest("PUT", "https://admin.test/api/v1/settings/gateway", strings.NewReader(`{}`))
	ctx.Request.Header.Set("Origin", "https://admin.test")
	ctx.Request.Header.Set("Content-Type", "application/json")
	h.GatewaySettings(ctx)
	if w.Code < 400 || calls != 1 || h.Gateway.Status().Candidate != nil {
		t.Fatal("mutation was not blocked")
	}
}

func TestGatewayStatusNeverContainsPrivateMaterial(t *testing.T) {
	h := NewManagement(gatewayService{})
	h.Gateway = gateway.New(t.TempDir(), func() string { return "http://localhost:9000" })
	w := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(w)
	ctx.Request = httptest.NewRequest(http.MethodGet, "/api/v1/settings/gateway", nil)
	h.GatewaySettings(ctx)
	if w.Code != 200 || strings.Contains(w.Body.String(), "private_key") {
		t.Fatal(w.Body.String())
	}
}
