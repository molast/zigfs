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
		if !isValidRequestID(requestID) {
			requestID = newRequestID()
		}

		ctx.Header(requestIDHeader, requestID)
		ctx.Request = ctx.Request.WithContext(requestid.WithContext(ctx.Request.Context(), requestID))
		ctx.Next()
	}
}

func isValidRequestID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range []byte(value) {
		if (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') ||
			char == '-' || char == '_' || char == '.' || char == ':' {
			continue
		}
		return false
	}
	return true
}

func newRequestID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "unavailable"
	}
	return hex.EncodeToString(value[:])
}
