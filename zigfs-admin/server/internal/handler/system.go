package handler

import (
	"context"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
	"zigfs-admin/server/internal/requestid"
)

type SystemService interface {
	Ready(ctx context.Context) error
	Get(ctx context.Context) (contract.SystemResponse, error)
}

type System struct {
	service SystemService
}

func NewSystem(service SystemService) *System {
	return &System{service: service}
}

func (handler *System) Live(ctx *gin.Context) {
	ctx.JSON(http.StatusOK, contract.HealthResponse{Status: "ok"})
}

func (handler *System) Ready(ctx *gin.Context) {
	if err := handler.service.Ready(ctx.Request.Context()); err != nil {
		var statusError *port.StatusError
		if errors.As(err, &statusError) {
			writeError(ctx, http.StatusServiceUnavailable, "StorageNotReady", "storage service is not ready")
		} else {
			writeError(ctx, http.StatusServiceUnavailable, "StorageOffline", "storage service is offline")
		}
		return
	}
	ctx.JSON(http.StatusOK, contract.HealthResponse{Status: "ready"})
}

func (handler *System) Get(ctx *gin.Context) {
	response, err := handler.service.Get(ctx.Request.Context())
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func writeStorageError(ctx *gin.Context, err error) {
	var statusError *port.StatusError
	if !errors.As(err, &statusError) {
		writeError(ctx, http.StatusServiceUnavailable, "StorageOffline", "storage service is offline")
		return
	}
	if statusError.StatusCode == http.StatusUnauthorized {
		writeError(ctx, http.StatusUnauthorized, "Unauthorized", "administrator session has expired")
		return
	}
	if statusError.Code != "" && statusError.StatusCode >= 400 && statusError.StatusCode < 600 {
		writeError(ctx, statusError.StatusCode, statusError.Code, statusError.Message)
		return
	}
	writeError(ctx, http.StatusBadGateway, "InvalidUpstreamResponse", "storage service returned an invalid response")
}

func writeError(ctx *gin.Context, status int, code, message string) {
	ctx.AbortWithStatusJSON(status, contract.ErrorResponse{
		Code:      code,
		Message:   message,
		RequestID: requestid.FromContext(ctx.Request.Context()),
		Details:   map[string]any{},
	})
}
