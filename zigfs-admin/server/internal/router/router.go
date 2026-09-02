package router

import (
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/handler"
	"zigfs-admin/server/internal/middleware"
)

func New(system *handler.System, management *handler.Management, webAdminToken, webRoot string) *gin.Engine {
	engine := gin.New()
	engine.Use(
		gin.Logger(),
		gin.Recovery(),
		middleware.RequestID(),
		middleware.SecurityHeaders(),
	)

	engine.GET("/health/live", system.Live)
	engine.GET("/health/ready", system.Ready)

	api := engine.Group("/api/v1")
	api.Use(middleware.RequireAdminToken(webAdminToken))
	api.GET("/system", system.Get)
	api.GET("/buckets", management.ListBuckets)
	api.POST("/buckets", management.CreateBucket)
	api.DELETE("/buckets/:name", management.DeleteBucket)
	api.GET("/buckets/:name/objects", management.ListObjects)
	api.POST("/objects/presign", management.PresignObject)
	api.GET("/access-keys", management.ListAccessKeys)
	api.POST("/access-keys", management.CreateAccessKey)
	api.PATCH("/access-keys/:id", management.UpdateAccessKey)
	api.DELETE("/access-keys/:id", management.DeleteAccessKey)

	engine.StaticFS("/assets", http.Dir(filepath.Join(webRoot, "assets")))
	engine.NoRoute(func(ctx *gin.Context) {
		if ctx.Request.Method != http.MethodGet || strings.HasPrefix(ctx.Request.URL.Path, "/api/") {
			ctx.Status(http.StatusNotFound)
			return
		}
		ctx.File(filepath.Join(webRoot, "index.html"))
	})

	return engine
}
