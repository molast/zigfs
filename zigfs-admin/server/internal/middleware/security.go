package middleware

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/requestid"
)

func SecurityHeaders() gin.HandlerFunc {
	return func(ctx *gin.Context) {
		ctx.Header("X-Content-Type-Options", "nosniff")
		ctx.Header("X-Frame-Options", "DENY")
		ctx.Header("Referrer-Policy", "no-referrer")
		ctx.Next()
	}
}

func RequireAdminToken(expected string) gin.HandlerFunc {
	return func(ctx *gin.Context) {
		provided := strings.TrimPrefix(ctx.GetHeader("Authorization"), "Bearer ")
		if !equalToken(provided, expected) {
			ctx.AbortWithStatusJSON(http.StatusUnauthorized, contract.ErrorResponse{
				Code:      "Unauthorized",
				Message:   "valid admin credentials are required",
				RequestID: requestid.FromContext(ctx.Request.Context()),
				Details:   map[string]any{},
			})
			return
		}
		ctx.Next()
	}
}

func equalToken(provided, expected string) bool {
	if provided == "" || expected == "" || len(provided) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}
