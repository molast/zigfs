package router

import (
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"

	"zigfs-admin/server/internal/handler"
	"zigfs-admin/server/internal/middleware"
)

func New(auth *handler.Auth, system *handler.System, management *handler.Management, webRoot string) *gin.Engine {
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
	api.POST("/auth/login", auth.Login)

	private := api.Group("")
	private.Use(middleware.RequireAdminSession())
	private.POST("/auth/logout", auth.Logout)
	private.GET("/auth/session", auth.Session)
	private.GET("/system", system.Get)
	private.GET("/storage", management.Storage)
	private.GET("/management-health", management.Health)
	private.GET("/settings", management.Settings)
	private.GET("/buckets", management.ListBuckets)
	private.POST("/buckets", management.CreateBucket)
	private.DELETE("/buckets/:name", management.DeleteBucket)
	private.GET("/buckets/:name/objects", management.ListObjects)
	private.POST("/objects/presign", management.PresignObject)
	private.GET("/access-keys", management.ListAccessKeys)
	private.POST("/access-keys", management.CreateAccessKey)
	private.PATCH("/access-keys/:id", management.UpdateAccessKey)
	private.DELETE("/access-keys/:id", management.DeleteAccessKey)

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
