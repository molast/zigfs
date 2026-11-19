package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/molast/zigfs/pkg/gateway"
)

func (h *Management) GatewaySettings(ctx *gin.Context) {
	// Cookie presence is insufficient. ZigFS checks the session and admin:*
	// permission on every request, including CA downloads and status reads.
	if _, err := h.service.Settings(ctx.Request.Context()); err != nil {
		writeStorageError(ctx, err)
		return
	}
	if h.Gateway == nil {
		writeError(ctx, 503, "GatewayUnavailable", "gateway is unavailable")
		return
	}
	if ctx.Request.Method != http.MethodGet {
		origin, err := url.Parse(ctx.GetHeader("Origin"))
		media, _, mediaErr := mime.ParseMediaType(ctx.GetHeader("Content-Type"))
		if err != nil || origin.Host != ctx.Request.Host || (ctx.Request.TLS != nil && origin.Scheme != "https") || (origin.Scheme != "http" && origin.Scheme != "https") || mediaErr != nil || media != "application/json" {
			writeError(ctx, 403, "InvalidGatewayOrigin", "gateway changes require same-origin JSON requests")
			return
		}
		ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 192*1024)
	}
	var expectedNetwork gateway.Network
	read := func() (gateway.Network, error) {
		settings, err := h.service.Settings(ctx.Request.Context())
		proxies := settings.TrustedProxies
		if proxies == nil {
			proxies = []string{}
		}
		expectedNetwork = gateway.Network{Endpoint: settings.S3PublicEndpoint, VirtualHosted: settings.S3VirtualHostedStyle, TrustedProxies: proxies}
		return expectedNetwork, err
	}
	write := func(network gateway.Network) error {
		data, err := json.Marshal(struct {
			gateway.Network
			Expected gateway.Network `json:"expected_network"`
		}{Network: network, Expected: expectedNetwork})
		if err != nil {
			return err
		}
		_, err = h.service.SaveNetworkSettings(ctx.Request.Context(), data)
		return err
	}
	action := strings.TrimPrefix(ctx.Request.URL.Path, "/api/v1/settings/gateway")
	auditOperation := ""
	if ctx.Request.Method == http.MethodPut {
		auditOperation = "prepare"
	}
	if action == "/apply" || action == "/rollback" {
		auditOperation = strings.TrimPrefix(action, "/")
	}
	if auditOperation != "" && h.GatewayAudit != nil {
		if err := h.GatewayAudit(ctx.Request.Context(), auditOperation, "requested"); err != nil {
			writeStorageError(ctx, err)
			return
		}
		defer func() {
			phase := "succeeded"
			if ctx.Writer.Status() >= 400 {
				phase = "failed"
			}
			if err := h.GatewayAudit(ctx.Request.Context(), auditOperation, phase); err != nil {
				slog.Error("gateway outcome report unavailable; requested event was already submitted", "operation", auditOperation)
			}
		}()
	}
	var err error
	switch {
	case ctx.Request.Method == http.MethodGet && action == "/local-setup.ps1":
		var script string
		script, err = h.Gateway.WindowsSetup()
		if err == nil {
			ctx.Header("Content-Disposition", `attachment; filename="zigfs-local-setup.ps1"`)
			ctx.Header("Cache-Control", "no-store")
			ctx.Data(200, "text/plain; charset=utf-8", []byte(script))
			return
		}
	case ctx.Request.Method == http.MethodGet && action == "/local-setup.sh":
		var script string
		script, err = h.Gateway.LocalSetup()
		if err == nil {
			ctx.Header("Content-Disposition", `attachment; filename="zigfs-local-setup.sh"`)
			ctx.Header("Cache-Control", "no-store")
			ctx.Data(200, "text/plain; charset=utf-8", []byte(script))
			return
		}
	case ctx.Request.Method == http.MethodGet && action == "/ca.crt":
		var cert string
		cert, err = h.Gateway.CA()
		if err == nil {
			ctx.Header("Content-Disposition", `attachment; filename="zigfs-local-ca.crt"`)
			ctx.Header("Cache-Control", "no-store")
			ctx.Data(200, "application/x-pem-file", []byte(cert))
			return
		}
	case ctx.Request.Method == http.MethodGet:
		ctx.Header("Cache-Control", "no-store")
		ctx.JSON(200, h.Gateway.Status())
		return
	case ctx.Request.Method == http.MethodPut:
		var input gateway.PrepareRequest
		if ctx.ShouldBindJSON(&input) != nil {
			writeError(ctx, 400, "InvalidRequest", "invalid gateway configuration")
			return
		}
		err = h.Gateway.Prepare(input)
	case action == "/check":
		err = h.Gateway.Check(ctx.Request.Context())
	default:
		var input struct {
			Revision       uint64 `json:"revision"`
			Disable        bool   `json:"disable"`
			Fallback       string `json:"fallback_endpoint"`
			ClientVerified bool   `json:"client_verified"`
		}
		if ctx.ShouldBindJSON(&input) != nil {
			writeError(ctx, 400, "InvalidRequest", "invalid gateway action")
			return
		}
		if action == "/rollback" {
			err = h.Gateway.Rollback(input.Revision, read, write)
		} else {
			if !input.Disable && !input.ClientVerified {
				writeError(ctx, 400, "GatewayVerificationRequired", "verify the candidate HTTPS endpoints from your browser first")
				return
			}
			err = h.Gateway.Apply(input.Revision, input.Disable, input.Fallback, read, write)
		}
	}
	if ctx.Request.Method != http.MethodGet {
		// Deployment diagnostics never include configuration bodies or key material.
		slog.Info("gateway configuration operation", "method", ctx.Request.Method, "action", action, "success", err == nil)
	}
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, gateway.ErrConflict) {
			status = http.StatusConflict
		}
		writeError(ctx, status, "GatewayConfigurationFailed", err.Error())
		return
	}
	ctx.JSON(200, h.Gateway.Status())
}
