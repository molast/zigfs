package handler

import (
	"context"
	"net/http"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
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
		writeError(ctx, http.StatusServiceUnavailable, "StorageNotReady", "storage service is not ready")
		return
	}
	ctx.JSON(http.StatusOK, contract.HealthResponse{Status: "ready"})
}

func (handler *System) Get(ctx *gin.Context) {
	response, err := handler.service.Get(ctx.Request.Context())
	if err != nil {
		writeError(ctx, http.StatusBadGateway, "StorageUnavailable", "storage service is unavailable")
		return
	}
	ctx.JSON(http.StatusOK, response)
}

func writeError(ctx *gin.Context, status int, code, message string) {
	ctx.AbortWithStatusJSON(status, contract.ErrorResponse{
		Code:      code,
		Message:   message,
		RequestID: requestid.FromContext(ctx.Request.Context()),
		Details:   map[string]any{},
	})
}
