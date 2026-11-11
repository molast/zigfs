const std = @import("std");
pub const categories = [_][]const u8{ "object_storage", "identity", "access_control", "bucket_management", "system_management", "kms", "security" };
pub const Spec = struct { name: []const u8, category: []const u8, resource_type: []const u8, service: []const u8, is_read_only: bool, method: []const u8 = "", path: []const u8 = "", alias: []const u8 = "" };
pub const operations = [_]Spec{
    .{ .name = "UnknownOperation", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = false },
    .{ .name = "UnknownOperation", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false },
    .{ .name = "ListBuckets", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "list_buckets" },
    .{ .name = "CreateBucket", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = false, .alias = "create_bucket" },
    .{ .name = "HeadBucket", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "head_bucket" },
    .{ .name = "GetBucketLocation", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "get_bucket_location" },
    .{ .name = "GetBucketPolicy", .category = "access_control", .resource_type = "policy", .service = "s3", .is_read_only = true, .alias = "get_bucket_policy" },
    .{ .name = "PutBucketPolicy", .category = "access_control", .resource_type = "policy", .service = "s3", .is_read_only = false, .alias = "put_bucket_policy" },
    .{ .name = "DeleteBucketPolicy", .category = "access_control", .resource_type = "policy", .service = "s3", .is_read_only = false, .alias = "delete_bucket_policy" },
    .{ .name = "GetBucketEncryption", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "get_bucket_encryption" },
    .{ .name = "PutBucketEncryption", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = false, .alias = "put_bucket_encryption" },
    .{ .name = "DeleteBucketEncryption", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = false, .alias = "delete_bucket_encryption" },
    .{ .name = "GetBucketVersioning", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "get_bucket_versioning" },
    .{ .name = "PutBucketVersioning", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = false, .alias = "put_bucket_versioning" },
    .{ .name = "GetBucketLifecycle", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "get_bucket_lifecycle" },
    .{ .name = "PutBucketLifecycle", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = false, .alias = "put_bucket_lifecycle" },
    .{ .name = "DeleteBucketLifecycle", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = false, .alias = "delete_bucket_lifecycle" },
    .{ .name = "DeleteBucket", .category = "bucket_management", .resource_type = "bucket", .service = "s3", .is_read_only = false, .alias = "delete_bucket" },
    .{ .name = "DeleteObjects", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "delete_objects" },
    .{ .name = "ListObjectsV2", .category = "object_storage", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "list_objects_v2" },
    .{ .name = "ListObjectVersions", .category = "object_storage", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "list_object_versions" },
    .{ .name = "ListMultipartUploads", .category = "object_storage", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "list_multipart_uploads" },
    .{ .name = "PutObject", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "put_object" },
    .{ .name = "GetObject", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = true, .alias = "get_object" },
    .{ .name = "GetObjectTagging", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = true, .alias = "get_object_tagging" },
    .{ .name = "PutObjectTagging", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "put_object_tagging" },
    .{ .name = "DeleteObjectTagging", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "delete_object_tagging" },
    .{ .name = "HeadObject", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = true, .alias = "head_object" },
    .{ .name = "DeleteObject", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "delete_object" },
    .{ .name = "CreateMultipartUpload", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "create_multipart_upload" },
    .{ .name = "UploadPart", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "upload_part" },
    .{ .name = "ListParts", .category = "object_storage", .resource_type = "bucket", .service = "s3", .is_read_only = true, .alias = "list_parts" },
    .{ .name = "CompleteMultipartUpload", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "complete_multipart_upload" },
    .{ .name = "AbortMultipartUpload", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "abort_multipart_upload" },
    .{ .name = "PostPolicyUpload", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "post_policy_upload" },
    .{ .name = "UnsupportedOperation", .category = "object_storage", .resource_type = "object", .service = "s3", .is_read_only = false, .alias = "unsupported" },
    .{ .name = "Login", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/login" },
    .{ .name = "STSLogin", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/sts-login" },
    .{ .name = "GetSession", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/auth/session" },
    .{ .name = "Logout", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/logout" },
    .{ .name = "ListLoginProviders", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/auth/oidc/providers" },
    .{ .name = "StartOIDCLogin", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/oidc/start" },
    .{ .name = "CompleteOIDCLogin", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/oidc/callback" },
    .{ .name = "RefreshSession", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/oidc/refresh" },
    .{ .name = "LogoutOIDC", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/oidc/logout" },
    .{ .name = "EndOIDCSession", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/oidc/end-session" },
    .{ .name = "BackchannelLogout", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/oidc/backchannel-logout" },
    .{ .name = "AssumeWebIdentity", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/auth/oidc/web-identity" },
    .{ .name = "ListUsers", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/users" },
    .{ .name = "CreateUser", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/users" },
    .{ .name = "GetUser", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/users/:id" },
    .{ .name = "UpdateUser", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/users/:id" },
    .{ .name = "UpdateUser", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/users/:id" },
    .{ .name = "DeleteUser", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/users/:id" },
    .{ .name = "ListGroups", .category = "identity", .resource_type = "group", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/groups" },
    .{ .name = "CreateGroup", .category = "identity", .resource_type = "group", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/groups" },
    .{ .name = "GetGroup", .category = "identity", .resource_type = "group", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/groups/:id" },
    .{ .name = "UpdateGroup", .category = "identity", .resource_type = "group", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/groups/:id" },
    .{ .name = "UpdateGroup", .category = "identity", .resource_type = "group", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/groups/:id" },
    .{ .name = "DeleteGroup", .category = "identity", .resource_type = "group", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/groups/:id" },
    .{ .name = "ListPolicies", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/policies" },
    .{ .name = "CreatePolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/policies" },
    .{ .name = "GetPolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/policies/:id" },
    .{ .name = "UpdatePolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/policies/:id" },
    .{ .name = "UpdatePolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/policies/:id" },
    .{ .name = "DeletePolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/policies/:id" },
    .{ .name = "ListRoles", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/roles" },
    .{ .name = "CreateRole", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/roles" },
    .{ .name = "GetRole", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/roles/:id" },
    .{ .name = "UpdateRole", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/roles/:id" },
    .{ .name = "UpdateRole", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/roles/:id" },
    .{ .name = "DeleteRole", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/roles/:id" },
    .{ .name = "ListOrganizations", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/organizations" },
    .{ .name = "CreateOrganization", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/organizations" },
    .{ .name = "GetOrganization", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/organizations/:id" },
    .{ .name = "UpdateOrganization", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/organizations/:id" },
    .{ .name = "UpdateOrganization", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/organizations/:id" },
    .{ .name = "DeleteOrganization", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/organizations/:id" },
    .{ .name = "ListAccessKeys", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/access-keys" },
    .{ .name = "CreateAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/access-keys" },
    .{ .name = "GetAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/access-keys/:id" },
    .{ .name = "UpdateAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/access-keys/:id" },
    .{ .name = "UpdateAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/access-keys/:id" },
    .{ .name = "DeleteAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/access-keys/:id" },
    .{ .name = "ListOIDCProviders", .category = "identity", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/oidc/providers" },
    .{ .name = "CreateOIDCProvider", .category = "identity", .resource_type = "system", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/oidc/providers" },
    .{ .name = "GetOIDCProvider", .category = "identity", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/oidc/providers/:id" },
    .{ .name = "UpdateOIDCProvider", .category = "identity", .resource_type = "system", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/oidc/providers/:id" },
    .{ .name = "UpdateOIDCProvider", .category = "identity", .resource_type = "system", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/oidc/providers/:id" },
    .{ .name = "DeleteOIDCProvider", .category = "identity", .resource_type = "system", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/oidc/providers/:id" },
    .{ .name = "ListUserAccessKeys", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/users/:id/access-keys" },
    .{ .name = "CreateUserAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/users/:id/access-keys" },
    .{ .name = "GetUserAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/users/:id/access-keys/:key" },
    .{ .name = "UpdateUserAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/users/:id/access-keys/:key" },
    .{ .name = "DeleteUserAccessKey", .category = "identity", .resource_type = "access_key", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/users/:id/access-keys/:key" },
    .{ .name = "ValidateOIDCProvider", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/oidc/validate" },
    .{ .name = "AssumeRole", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/sts/assume-role" },
    .{ .name = "ListRoleSessions", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/role-sessions" },
    .{ .name = "RevokeRoleSession", .category = "identity", .resource_type = "user", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/role-sessions/:id/revoke" },
    .{ .name = "ListBuckets", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets" },
    .{ .name = "CreateBucket", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/buckets" },
    .{ .name = "DeleteBucket", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/buckets/:bucket" },
    .{ .name = "GetBucketConfiguration", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/configuration" },
    .{ .name = "UpdateBucketConfiguration", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/buckets/:bucket/configuration" },
    .{ .name = "GetBucketUsage", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/usage" },
    .{ .name = "GetBucketTags", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/tags" },
    .{ .name = "PutBucketTags", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/buckets/:bucket/tags" },
    .{ .name = "DeleteBucketTags", .category = "bucket_management", .resource_type = "bucket", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/buckets/:bucket/tags" },
    .{ .name = "GetBucketPolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/policy" },
    .{ .name = "PutBucketPolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/buckets/:bucket/policy" },
    .{ .name = "DeleteBucketPolicy", .category = "access_control", .resource_type = "policy", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/buckets/:bucket/policy" },
    .{ .name = "ListObjects", .category = "object_storage", .resource_type = "bucket", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/objects" },
    .{ .name = "ListObjectVersions", .category = "object_storage", .resource_type = "bucket", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/versions" },
    .{ .name = "ListMultipartUploads", .category = "object_storage", .resource_type = "bucket", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/multipart-uploads" },
    .{ .name = "CreateDirectory", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/buckets/:bucket/directories" },
    .{ .name = "DeleteDirectory", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/buckets/:bucket/directories" },
    .{ .name = "CleanupDirectory", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/buckets/:bucket/directories/cleanup" },
    .{ .name = "SetObjectLegalHold", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "PATCH", .path = "/_admin/v1/buckets/:bucket/legal-hold" },
    .{ .name = "PresignObject", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/objects/presign" },
    .{ .name = "CreateMultipartUpload", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/multipart-uploads" },
    .{ .name = "ListParts", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/multipart-uploads/:id" },
    .{ .name = "CompleteMultipartUpload", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/multipart-uploads/:id/complete" },
    .{ .name = "AbortMultipartUpload", .category = "object_storage", .resource_type = "object", .service = "admin", .is_read_only = false, .method = "DELETE", .path = "/_admin/v1/multipart-uploads/:id" },
    .{ .name = "GetStorage", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/storage" },
    .{ .name = "GetStorageScanner", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/storage/scanner" },
    .{ .name = "RunGarbageCollection", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = false, .method = "POST", .path = "/_admin/v1/storage/gc" },
    .{ .name = "GetSystemInfo", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/system" },
    .{ .name = "GetSettings", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/settings" },
    .{ .name = "GetManagementHealth", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/health" },
    .{ .name = "GetLogConfiguration", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/settings/logs" },
    .{ .name = "UpdateLogConfiguration", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/settings/logs" },
    .{ .name = "QueryRuntimeLogs", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/settings/logs/query" },
    .{ .name = "DownloadRuntimeLogs", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/settings/logs/download" },
    .{ .name = "ListAuditEvents", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/audit-events" },
    .{ .name = "ListAuditOperations", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/audit-events/options" },
    .{ .name = "ListBucketAuditEvents", .category = "system_management", .resource_type = "system", .service = "admin", .is_read_only = true, .method = "GET", .path = "/_admin/v1/buckets/:bucket/events" },
    .{ .name = "GetKMSConfiguration", .category = "kms", .resource_type = "system", .service = "kms", .is_read_only = true, .method = "GET", .path = "/_admin/v1/settings/kms" },
    .{ .name = "UpdateKMSConfiguration", .category = "kms", .resource_type = "system", .service = "kms", .is_read_only = false, .method = "PUT", .path = "/_admin/v1/settings/kms" },
    .{ .name = "StartKMS", .category = "kms", .resource_type = "system", .service = "kms", .is_read_only = false, .method = "POST", .path = "/_admin/v1/settings/kms/start" },
    .{ .name = "StopKMS", .category = "kms", .resource_type = "system", .service = "kms", .is_read_only = false, .method = "POST", .path = "/_admin/v1/settings/kms/stop" },
    .{ .name = "ClearKMSCache", .category = "kms", .resource_type = "system", .service = "kms", .is_read_only = false, .method = "POST", .path = "/_admin/v1/settings/kms/clear-cache" },
    .{ .name = "ListKeys", .category = "kms", .resource_type = "kms_key", .service = "kms", .is_read_only = true, .method = "GET", .path = "/_admin/v1/settings/kms/keys" },
    .{ .name = "CreateKey", .category = "kms", .resource_type = "kms_key", .service = "kms", .is_read_only = false, .method = "POST", .path = "/_admin/v1/settings/kms/keys" },
    .{ .name = "KeyAction", .category = "kms", .resource_type = "kms_key", .service = "kms", .is_read_only = false, .method = "POST", .path = "/_admin/v1/settings/kms/keys/action" },
    .{ .name = "DeleteKey", .category = "kms", .resource_type = "kms_key", .service = "kms", .is_read_only = false, .alias = "kms:delete" },
    .{ .name = "ScheduleKeyDeletion", .category = "kms", .resource_type = "kms_key", .service = "kms", .is_read_only = false, .alias = "kms:schedule-deletion" },
    .{ .name = "CancelKeyDeletion", .category = "kms", .resource_type = "kms_key", .service = "kms", .is_read_only = false, .alias = "kms:cancel-deletion" },
    .{ .name = "RotateKey", .category = "kms", .resource_type = "kms_key", .service = "kms", .is_read_only = false, .alias = "kms:rotate" },
    .{ .name = "AssumeRoleWithWebIdentity", .category = "identity", .resource_type = "user", .service = "sts", .is_read_only = false, .alias = "sts:AssumeRoleWithWebIdentity" },
};
pub const Query = struct { versionId: ?[]const u8 = null, uploadId: ?[]const u8 = null, prefix: ?[]const u8 = null, key: ?[]const u8 = null };
pub const Request = struct { request_id: []const u8 = "", method: []const u8 = "", protocol: ?[]const u8 = null, path: []const u8 = "", query: Query = .{}, user_agent: ?[]const u8 = null, source_ip: ?[]const u8 = null };
pub const Identity = struct { auth_type: []const u8 = "anonymous", principal_id: ?[]const u8 = null, principal_name: ?[]const u8 = null, access_key_id: ?[]const u8 = null, session_id: ?[]const u8 = null };
pub const Resource = struct { type: []const u8 = "system", bucket: ?[]const u8 = null, object_key: ?[]const u8 = null, version_id: ?[]const u8 = null, name: ?[]const u8 = null };
pub const Operation = struct { name: []const u8 = "UnknownOperation", service: []const u8 = "admin", is_read_only: bool = false };
pub const Response = struct { status: []const u8 = "unknown", http_status: u16 = 0, error_code: ?[]const u8 = null, error_message: ?[]const u8 = null, duration_ms: u64 = 0 };
pub const Metadata = struct { region: ?[]const u8 = null, server_id: ?[]const u8 = null, legacy: bool = false };
pub const Event = struct {
    schema_version: []const u8 = "1.0",
    event_id: []const u8 = "",
    event_time: []const u8 = "",
    event_category: []const u8 = "system_management",
    event_type: []const u8 = "admin_action",
    event_action: []const u8 = "UnknownOperation",
    request: Request = .{},
    identity: Identity = .{},
    resource: Resource = .{},
    operation: Operation = .{},
    response: Response = .{},
    metadata: Metadata = .{},
    // Compatibility fields retained for existing bucket-event clients and old stored records.
    timestamp_unix_seconds: i64 = 0,
    request_id: []const u8 = "",
    actor: []const u8 = "anonymous",
    action: []const u8 = "",
    target: []const u8 = "",
    outcome: []const u8 = "",
};
pub const Filters = struct { category: ?[]const u8 = null, service: ?[]const u8 = null, event_type: ?[]const u8 = null, actor: ?[]const u8 = null, bucket: ?[]const u8 = null, request_id: ?[]const u8 = null, source_ip: ?[]const u8 = null };

pub fn matches(event: Event, filters: Filters) bool {
    if (filters.category) |v| if (!std.mem.eql(u8, v, event.event_category)) return false;
    if (filters.service) |v| if (!std.mem.eql(u8, v, event.operation.service)) return false;
    if (filters.event_type) |v| if (!std.mem.eql(u8, v, event.event_type)) return false;
    if (filters.actor) |v| if (!std.mem.eql(u8, v, event.identity.principal_name orelse "") and !std.mem.eql(u8, v, event.identity.principal_id orelse "") and !std.mem.eql(u8, v, event.actor)) return false;
    if (filters.bucket) |v| if (!std.mem.eql(u8, v, event.resource.bucket orelse "")) return false;
    if (filters.request_id) |v| if (!std.mem.eql(u8, v, event.request.request_id)) return false;
    if (filters.source_ip) |v| if (!std.mem.eql(u8, v, event.request.source_ip orelse "")) return false;
    return true;
}
fn routeMatches(pattern: []const u8, path: []const u8) bool {
    var a = std.mem.splitScalar(u8, pattern, '/');
    var b = std.mem.splitScalar(u8, path, '/');
    while (a.next()) |part| {
        const value = b.next() orelse return false;
        if (std.mem.startsWith(u8, part, ":")) {
            if (value.len == 0) return false;
        } else if (!std.mem.eql(u8, part, value)) return false;
    }
    return b.next() == null;
}
pub fn classify(action: []const u8, method: []const u8, path: []const u8) Spec {
    for (operations) |spec| if (spec.alias.len > 0 and std.mem.eql(u8, action, spec.alias)) return spec;
    for (operations) |spec| {
        if (spec.path.len > 0 and std.mem.eql(u8, method, spec.method) and routeMatches(spec.path, path)) return spec;
    }
    return .{ .name = "UnknownOperation", .category = "system_management", .resource_type = "system", .service = if (std.mem.startsWith(u8, path, "/_admin/")) "admin" else "s3", .is_read_only = std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD") };
}
pub fn statusName(code: u16) []const u8 {
    return if (code == 0) "unknown" else if (code == 401 or code == 403) "denied" else if (code >= 500) "error" else if (code >= 400) "failure" else "success";
}
pub fn decode(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch {
                try out.append(a, raw[i]);
                continue;
            };
            try out.append(a, byte);
            i += 2;
        } else try out.append(a, raw[i]);
    }
    return out.toOwnedSlice(a);
}
pub fn resourceFor(a: std.mem.Allocator, path: []const u8, spec: Spec, query: Query) !Resource {
    var resource: Resource = .{ .type = spec.resource_type, .version_id = query.versionId };
    const admin = "/_admin/v1/buckets/";
    if (std.mem.startsWith(u8, path, admin)) {
        const tail = path[admin.len..];
        resource.bucket = try decode(a, tail[0 .. std.mem.indexOfScalar(u8, tail, '/') orelse tail.len]);
        resource.object_key = query.key;
    } else if (std.mem.eql(u8, spec.service, "s3") and path.len > 1) {
        const tail = path[1..];
        const slash = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
        resource.bucket = try a.dupe(u8, tail[0..slash]);
        if (slash < tail.len) resource.object_key = try a.dupe(u8, tail[slash + 1 ..]);
    } else if (std.mem.eql(u8, spec.service, "kms") and !std.mem.startsWith(u8, path, "/")) {
        resource.name = try a.dupe(u8, path);
    } else if (spec.path.len > 0) {
        var pattern = std.mem.splitScalar(u8, spec.path, '/');
        var actual = std.mem.splitScalar(u8, path, '/');
        while (pattern.next()) |segment| {
            const value = actual.next() orelse break;
            if (std.mem.startsWith(u8, segment, ":") and pattern.peek() == null) resource.name = try decode(a, value);
        }
    }
    return resource;
}
// Deep-copy/free only data structs, byte strings, optional values and scalar fields.
fn copy(comptime T: type, a: std.mem.Allocator, value: T) !T {
    if (T == []const u8) return a.dupe(u8, value);
    return switch (@typeInfo(T)) {
        .optional => |info| if (value) |v| try copy(info.child, a, v) else null,
        .@"struct" => |info| blk: {
            var result: T = undefined;
            var done: usize = 0;
            errdefer inline for (info.field_names, info.field_types, 0..) |name, Field, i| {
                if (i < done) release(Field, a, @field(result, name));
            };
            inline for (info.field_names, info.field_types) |name, Field| {
                @field(result, name) = try copy(Field, a, @field(value, name));
                done += 1;
            }
            break :blk result;
        },
        else => value,
    };
}
fn release(comptime T: type, a: std.mem.Allocator, value: T) void {
    if (T == []const u8) {
        a.free(value);
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |info| if (value) |v| {
            release(info.child, a, v);
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            release(Field, a, @field(value, name));
        },
        else => {},
    }
}
pub fn free(a: std.mem.Allocator, value: Event) void {
    release(Event, a, value);
}
pub fn clone(a: std.mem.Allocator, value: Event) !Event {
    if (value.event_id.len > 0) return copy(Event, a, value);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var legacy = value;
    const encoded = try std.json.Stringify.valueAlloc(temp, value, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    legacy.event_id = try std.fmt.allocPrint(temp, "legacy_{s}", .{std.fmt.bytesToHex(digest, .lower)});
    var time_buffer: [20]u8 = undefined;
    legacy.event_time = @import("../common/time.zig").formatIso8601(value.timestamp_unix_seconds, &time_buffer) catch "1970-01-01T00:00:00Z";
    const space = std.mem.indexOfScalar(u8, value.action, ' ');
    const method = if (space) |i| value.action[0..i] else "";
    const spec = classify(value.action, method, value.target);
    legacy.event_category = spec.category;
    legacy.event_action = spec.name;
    legacy.event_type = if (std.mem.eql(u8, spec.service, "s3")) "api_request" else "admin_action";
    legacy.request = .{ .request_id = value.request_id, .method = method, .path = value.target };
    legacy.identity = .{ .auth_type = if (std.mem.eql(u8, value.actor, "anonymous")) "anonymous" else "unknown", .principal_name = value.actor };
    legacy.resource = try resourceFor(temp, value.target, spec, .{});
    legacy.operation = .{ .name = spec.name, .service = spec.service, .is_read_only = spec.is_read_only };
    if (std.mem.lastIndexOfScalar(u8, value.outcome, ':')) |i| legacy.response.http_status = std.fmt.parseInt(u16, value.outcome[i + 1 ..], 10) catch 0;
    legacy.response.status = statusName(legacy.response.http_status);
    if (std.mem.eql(u8, legacy.response.status, "denied")) {
        legacy.event_category = "security";
        legacy.event_type = "security_event";
    }
    legacy.metadata.legacy = true;
    return copy(Event, a, legacy);
}

pub fn cloneResource(a: std.mem.Allocator, value: Resource) !Resource {
    return copy(Resource, a, value);
}

test "operation classification separates categories and prioritizes explicit KMS actions" {
    const put = classify("put_object", "PUT", "/photos/a.jpg");
    try std.testing.expectEqualStrings("PutObject", put.name);
    try std.testing.expectEqualStrings("object_storage", put.category);
    try std.testing.expect(!put.is_read_only);
    const policy = classify("put_bucket_policy", "PUT", "/photos");
    try std.testing.expectEqualStrings("access_control", policy.category);
    const user = classify("POST /_admin/v1/users", "POST", "/_admin/v1/users");
    try std.testing.expectEqualStrings("CreateUser", user.name);
    const key = classify("kms:rotate", "POST", "/_admin/v1/settings/kms/keys/action");
    try std.testing.expectEqualStrings("RotateKey", key.name);
    try std.testing.expectEqualStrings("denied", statusName(403));
    try std.testing.expectEqualStrings("failure", statusName(400));
    try std.testing.expectEqualStrings("error", statusName(503));
}

test "legacy events migrate deterministically and preserve unavailable context" {
    const old: Event = .{ .timestamp_unix_seconds = 10, .request_id = "old-id", .actor = "alice", .action = "put_object", .target = "/photos/file.txt", .outcome = "success:200" };
    const first = try clone(std.testing.allocator, old);
    defer free(std.testing.allocator, first);
    const second = try clone(std.testing.allocator, old);
    defer free(std.testing.allocator, second);
    try std.testing.expectEqualStrings(first.event_id, second.event_id);
    try std.testing.expect(first.metadata.legacy);
    try std.testing.expect(first.request.source_ip == null);
    try std.testing.expect(first.identity.principal_id == null);
    try std.testing.expectEqualStrings("unknown", first.identity.auth_type);
    try std.testing.expectEqualStrings("PutObject", first.event_action);
    try std.testing.expectEqualStrings("photos", first.resource.bucket.?);
    try std.testing.expectEqualStrings("file.txt", first.resource.object_key.?);
    try std.testing.expect(matches(first, .{ .category = "object_storage", .actor = "alice", .bucket = "photos" }));
    try std.testing.expect(!matches(first, .{ .category = "kms" }));
    const third = try clone(std.testing.allocator, first);
    defer free(std.testing.allocator, third);
    try std.testing.expectEqualStrings(first.event_id, third.event_id);
}
