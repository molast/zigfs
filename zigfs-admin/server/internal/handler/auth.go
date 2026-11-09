package handler

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/middleware"
	"zigfs-admin/server/internal/port"
)

type AuthService interface {
	Logout(context.Context) error
	Login(context.Context, contract.LoginRequest) (contract.LoginResponse, error)
	STSLogin(context.Context, contract.STSLoginRequest) (contract.LoginResponse, error)
	Session(context.Context) (contract.SessionResponse, error)
}

func (handler *Auth) STSLogin(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	var request contract.STSLoginRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "STS username, secret key and session token are required")
		return
	}
	response, err := handler.service.STSLogin(ctx.Request.Context(), request)
	if err != nil {
		if status, ok := err.(*port.StatusError); ok && status.StatusCode == http.StatusUnauthorized {
			writeError(ctx, http.StatusUnauthorized, "Unauthorized", "invalid STS credentials")
			return
		}
		writeError(ctx, http.StatusServiceUnavailable, "StorageOffline", "ZigFS authentication is unavailable")
		return
	}
	maxAge := int(time.Until(time.Unix(response.ExpiresAt, 0)).Seconds())
	if maxAge < 1 {
		writeError(ctx, http.StatusBadGateway, "InvalidUpstreamResponse", "ZigFS returned an expired session")
		return
	}
	ctx.SetSameSite(http.SameSiteStrictMode)
	ctx.SetCookie(middleware.AdminSessionCookie, response.Token, maxAge, "/api", "", false, true)
	ctx.JSON(http.StatusOK, contract.SessionResponse{Authenticated: true, SubjectID: response.SubjectID, IsRoot: response.IsRoot, Username: response.Username, ExpiresAt: response.ExpiresAt})
}

type Auth struct {
	service AuthService
}

func NewAuth(service AuthService) *Auth {
	return &Auth{service: service}
}

func (handler *Auth) Login(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	var request contract.LoginRequest
	if err := ctx.ShouldBindJSON(&request); err != nil {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "username and password are required")
		return
	}

	response, err := handler.service.Login(ctx.Request.Context(), request)
	if err != nil {
		var statusError *port.StatusError
		if errors.As(err, &statusError) && statusError.StatusCode == http.StatusUnauthorized {
			writeError(ctx, http.StatusUnauthorized, "Unauthorized", "invalid username or password")
			return
		}
		writeError(ctx, http.StatusServiceUnavailable, "StorageOffline", "ZigFS authentication is unavailable")
		return
	}

	maxAge := int(time.Until(time.Unix(response.ExpiresAt, 0)).Seconds())
	if maxAge < 1 {
		writeError(ctx, http.StatusBadGateway, "InvalidUpstreamResponse", "ZigFS returned an expired session")
		return
	}
	ctx.SetSameSite(http.SameSiteStrictMode)
	ctx.SetCookie(middleware.AdminSessionCookie, response.Token, maxAge, "/api", "", false, true)
	ctx.JSON(http.StatusOK, contract.SessionResponse{
		Authenticated: true,
		SubjectID:     response.SubjectID,
		IsRoot:        response.IsRoot,
		Username:      response.Username,
		ExpiresAt:     response.ExpiresAt,
	})
}

func (handler *Auth) Logout(ctx *gin.Context) {
	if err := handler.service.Logout(ctx.Request.Context()); err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Header("Cache-Control", "no-store")
	ctx.SetSameSite(http.SameSiteStrictMode)
	ctx.SetCookie(middleware.AdminSessionCookie, "", -1, "/api", "", false, true)
	ctx.Status(http.StatusNoContent)
}

func (handler *Auth) Session(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	response, err := handler.service.Session(ctx.Request.Context())
	if err != nil {
		var statusError *port.StatusError
		if errors.As(err, &statusError) && statusError.StatusCode == http.StatusUnauthorized {
			writeError(ctx, http.StatusUnauthorized, "Unauthorized", "session has expired")
			return
		}
		writeError(ctx, http.StatusServiceUnavailable, "StorageOffline", "ZigFS authentication is unavailable")
		return
	}
	ctx.JSON(http.StatusOK, response)
}
