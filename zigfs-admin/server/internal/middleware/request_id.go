package middleware

import (
	"crypto/rand"
	"encoding/hex"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/requestid"
)

const requestIDHeader = "X-Request-ID"

func RequestID() gin.HandlerFunc {
	return func(ctx *gin.Context) {
		requestID := ctx.GetHeader(requestIDHeader)
		if requestID == "" || len(requestID) > 128 {
			requestID = newRequestID()
		}

		ctx.Header(requestIDHeader, requestID)
		ctx.Request = ctx.Request.WithContext(requestid.WithContext(ctx.Request.Context(), requestID))
		ctx.Next()
	}
}

func newRequestID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "unavailable"
	}
	return hex.EncodeToString(value[:])
}
