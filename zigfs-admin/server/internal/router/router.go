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
		gin.LoggerWithConfig(gin.LoggerConfig{SkipPaths: []string{"/api/v1/auth/oidc/callback"}}),
		gin.Recovery(),
		middleware.RequestID(),
		middleware.SecurityHeaders(),
	)

	engine.GET("/health/live", system.Live)
	engine.GET("/health/ready", system.Ready)

	api := engine.Group("/api/v1")
	api.POST("/auth/login", auth.Login)
	api.POST("/auth/sts-login", auth.STSLogin)
	api.GET("/auth/oidc/providers", management.OIDCLoginProviders)
	api.POST("/auth/oidc/web-identity", management.OIDCWebIdentity)
	api.GET("/auth/oidc/:id/start", management.OIDCLoginStart)
	api.GET("/auth/oidc/callback", management.OIDCLoginCallback)
	api.POST("/auth/oidc/refresh", management.OIDCRefresh)
	api.POST("/auth/oidc/end-session", management.OIDCEndSession)
	api.POST("/auth/oidc/:id/backchannel-logout", management.OIDCBackchannelLogout)

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
	private.GET("/settings/kms", management.KMSSettings)
	private.PUT("/settings/kms", management.SaveKMSSettings)
	private.POST("/settings/kms/start", management.StartKMS)
	private.GET("/settings/kms/keys", management.KMSKeys)
	private.POST("/settings/kms/keys", management.KMSKeys)
	private.POST("/settings/kms/keys/action", management.KMSKeys)
	private.POST("/settings/kms/clear-cache", management.ClearKMSCache)
	private.POST("/settings/kms/stop", management.StopKMS)
	private.POST("/oidc/validate", management.OIDCProviders)
	private.GET("/oidc/providers", management.OIDCProviders)
	private.POST("/oidc/providers", management.OIDCProviders)
	private.PATCH("/oidc/providers/:id", management.OIDCProviders)
	private.DELETE("/oidc/providers/:id", management.OIDCProviders)
	private.GET("/users/:name/access-keys", management.ListUserAccessKeys)
	private.POST("/users/:name/access-keys", management.CreateUserAccessKey)
	private.PATCH("/users/:name/access-keys/:id", management.UpdateUserAccessKey)
	private.DELETE("/users/:name/access-keys/:id", management.DeleteUserAccessKey)
	private.GET("/organizations", management.ListOrganizations)
	private.POST("/organizations", management.CreateOrganization)
	private.PATCH("/organizations/:name", management.UpdateOrganization)
	private.DELETE("/organizations/:name", management.DeleteOrganization)
	private.GET("/roles", management.ListRoles)
	private.POST("/roles", management.CreateRole)
	private.PATCH("/roles/:name", management.UpdateRole)
	private.DELETE("/roles/:name", management.DeleteRole)
	private.POST("/sts/assume-role", management.AssumeRole)
	private.GET("/role-sessions", management.ListRoleSessions)
	private.POST("/role-sessions/:access_key/revoke", management.RevokeRoleSession)
	private.GET("/users", management.ListUsers)
	private.GET("/users/:name", management.GetUser)
	private.POST("/users", management.CreateUser)
	private.PATCH("/users/:name", management.UpdateUser)
	private.DELETE("/users/:name", management.DeleteUser)
	private.GET("/groups", management.ListGroups)
	private.GET("/groups/:name", management.GetGroup)
	private.POST("/groups", management.CreateGroup)
	private.PATCH("/groups/:name", management.UpdateGroup)
	private.DELETE("/groups/:name", management.DeleteGroup)
	private.GET("/policies", management.ListPolicies)
	private.GET("/policies/:name", management.GetPolicy)
	private.POST("/policies", management.CreatePolicy)
	private.PATCH("/policies/:name", management.UpdatePolicy)
	private.DELETE("/policies/:name", management.DeletePolicy)
	private.GET("/buckets", management.ListBuckets)
	private.POST("/buckets", management.CreateBucket)
	private.DELETE("/buckets/:name", management.DeleteBucket)
	private.GET("/buckets/:name/configuration", management.GetBucketConfiguration)
	private.GET("/buckets/:name/usage", management.GetBucketUsage)
	private.GET("/buckets/:name/events", management.ListBucketEvents)
	private.GET("/buckets/:name/policy", management.GetBucketPolicy)
	private.PUT("/buckets/:name/policy", management.PutBucketPolicy)
	private.DELETE("/buckets/:name/policy", management.DeleteBucketPolicy)
	private.GET("/buckets/:name/tags", management.GetBucketTags)
	private.PUT("/buckets/:name/tags", management.PutBucketTags)
	private.DELETE("/buckets/:name/tags", management.DeleteBucketTags)
	private.PATCH("/buckets/:name/configuration", management.UpdateBucketConfiguration)
	private.GET("/buckets/:name/versions", management.ListObjectVersions)
	private.GET("/buckets/:name/objects", management.ListObjects)
	private.POST("/buckets/:name/directories", management.CreateDirectory)
	private.DELETE("/buckets/:name/directories", management.DeleteDirectory)
	private.POST("/buckets/:name/directories/cleanup", management.ForceCleanupDirectory)
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
