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
	private.GET("/storage/scanner", management.StorageScanner)
	private.POST("/storage/gc", management.RunStorageGC)
	private.GET("/management-health", management.Health)
	private.GET("/settings", management.Settings)
	private.GET("/buckets", management.ListBuckets)
	private.POST("/buckets", management.CreateBucket)
	private.DELETE("/buckets/:name", management.DeleteBucket)
	private.GET("/buckets/:name/configuration", management.GetBucketConfiguration)
	private.GET("/buckets/:name/usage", management.GetBucketUsage)
	private.GET("/buckets/:name/events", management.ListBucketEvents)
	private.GET("/buckets/:name/tags", management.GetBucketTags)
	private.PUT("/buckets/:name/tags", management.PutBucketTags)
	private.DELETE("/buckets/:name/tags", management.DeleteBucketTags)
	private.PATCH("/buckets/:name/configuration", management.UpdateBucketConfiguration)
	private.GET("/buckets/:name/versions", management.ListObjectVersions)
	private.GET("/buckets/:name/objects", management.ListObjects)
	private.POST("/buckets/:name/directories", management.CreateDirectory)
	private.DELETE("/buckets/:name/directories", management.DeleteDirectory)
	private.GET("/buckets/:name/multipart-uploads", management.ListMultipartUploads)
	private.POST("/objects/presign", management.PresignObject)
	private.POST("/multipart-uploads", management.CreateMultipartUpload)
	private.GET("/multipart-uploads/:id", management.GetMultipartUpload)
	private.POST("/multipart-uploads/:id/complete", management.CompleteMultipartUpload)
	private.DELETE("/multipart-uploads/:id", management.AbortMultipartUpload)
	private.GET("/access-keys", management.ListAccessKeys)
	private.POST("/access-keys", management.CreateAccessKey)
	private.PATCH("/access-keys/:id", management.UpdateAccessKey)
	private.DELETE("/access-keys/:id", management.DeleteAccessKey)

	// Vite copies files from web/public to the web root. Serve the brand assets
	// explicitly before the SPA fallback, otherwise NoRoute returns index.html
	// for image requests and browsers render a broken image or default favicon.
	for _, asset := range []string{
		"zigfs-logo.svg",
		"favicon-32x32.png",
		"icon-192x192.png",
		"apple-touch-icon.png",
	} {
		engine.StaticFile("/"+asset, filepath.Join(webRoot, asset))
	}
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
