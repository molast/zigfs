package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/requestid"
)

const AdminSessionCookie = "zigfs_admin_session"

func SecurityHeaders() gin.HandlerFunc {
	return func(ctx *gin.Context) {
		ctx.Header("X-Content-Type-Options", "nosniff")
		ctx.Header("X-Frame-Options", "DENY")
		ctx.Header("Referrer-Policy", "no-referrer")
		ctx.Next()
	}
}

func RequireAdminSession() gin.HandlerFunc {
	return func(ctx *gin.Context) {
		token, err := ctx.Cookie(AdminSessionCookie)
		if err != nil || token == "" {
			ctx.AbortWithStatusJSON(http.StatusUnauthorized, contract.ErrorResponse{
				Code:      "Unauthorized",
				Message:   "a valid ZigFS administrator session is required",
				RequestID: requestid.FromContext(ctx.Request.Context()),
				Details:   map[string]any{},
			})
			return
		}
		ctx.Request = ctx.Request.WithContext(managementauth.WithToken(ctx.Request.Context(), token))
		ctx.Next()
	}
}
