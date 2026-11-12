package middleware

import (
	"github.com/gin-gonic/gin"
	"zigfs-admin/server/internal/managementauth"
)

func Forwarding() gin.HandlerFunc {
	return func(ctx *gin.Context) {
		ctx.Request = ctx.Request.WithContext(managementauth.WithForwarding(ctx.Request.Context(), ctx.Request))
		ctx.Next()
	}
}
