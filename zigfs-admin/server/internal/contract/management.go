package contract

import "time"

type Bucket struct {
	Name             string    `json:"name"`
	Owner            string    `json:"owner"`
	CreatedAt        time.Time `json:"created_at"`
	Versioning       string    `json:"versioning"`
	LifecycleEnabled bool      `json:"lifecycle_enabled"`
	TagsJSON         string    `json:"tags_json,omitempty"`
}

type BucketConfiguration struct {
	Name                   string  `json:"name"`
	Versioning             string  `json:"versioning"`
	AccessPolicy           string  `json:"access_policy"`
	TagsJSON               string  `json:"tags_json,omitempty"`
	Encryption             string  `json:"encryption"`
	KmsKeyID               string  `json:"kms_key_id"`
	MaxBytes               *uint64 `json:"max_bytes,omitempty"`
	MaxObjects             *uint64 `json:"max_objects,omitempty"`
	RetentionEnabled       bool    `json:"retention_enabled"`
	RetentionDuration      *uint64 `json:"retention_duration_seconds,omitempty"`
	RetentionMode          *string `json:"retention_mode,omitempty"`
	ObjectLocking          bool    `json:"object_locking"`
	ReplicationStatus      string  `json:"replication_status"`
	ReplicationEnabled     bool    `json:"replication_enabled"`
	ReplicationReason      string  `json:"replication_reason"`
	LifecycleConfiguration string  `json:"lifecycle_configuration,omitempty"`
}

type BucketUsage struct {
	Bytes   uint64 `json:"bytes"`
	Objects uint64 `json:"objects"`
}

type AuditEvent struct {
	Timestamp int64  `json:"timestamp_unix_seconds"`
	RequestID string `json:"request_id"`
	Actor     string `json:"actor"`
	Action    string `json:"action"`
	Target    string `json:"target"`
	Outcome   string `json:"outcome"`
}

type ListBucketEventsResponse struct {
	Items      []AuditEvent `json:"items"`
	NextCursor string       `json:"next_cursor,omitempty"`
}

type BucketTags struct {
	TagsJSON string `json:"tags_json,omitempty"`
}

type UpdateBucketConfigurationRequest struct {
	Versioning             string  `json:"versioning,omitempty"`
	AccessPolicy           string  `json:"access_policy,omitempty"`
	BlockPublicAccess      *bool   `json:"block_public_access,omitempty"`
	TagsJSON               string  `json:"tags_json,omitempty"`
	ClearTags              bool    `json:"clear_tags,omitempty"`
	Encryption             string  `json:"encryption,omitempty"`
	KmsKeyID               string  `json:"kms_key_id,omitempty"`
	MaxBytes               *uint64 `json:"max_bytes,omitempty"`
	MaxObjects             *uint64 `json:"max_objects,omitempty"`
	RetentionEnabled       *bool   `json:"retention_enabled,omitempty"`
	RetentionDuration      *uint64 `json:"retention_duration_seconds,omitempty"`
	RetentionMode          *string `json:"retention_mode,omitempty"`
	ObjectLocking          *bool   `json:"object_locking,omitempty"`
	ReplicationEnabled     *bool   `json:"replication_enabled,omitempty"`
	LifecycleConfiguration string  `json:"lifecycle_configuration,omitempty"`
	ClearLifecycle         bool    `json:"clear_lifecycle,omitempty"`
}

type ObjectVersion struct {
	Key            string    `json:"key"`
	VersionID      string    `json:"version_id"`
	IsLatest       bool      `json:"is_latest"`
	IsDeleteMarker bool      `json:"is_delete_marker"`
	Size           int64     `json:"size"`
	LastModified   time.Time `json:"last_modified"`
	RetentionUntil *int64    `json:"retention_until_unix_seconds,omitempty"`
	RetentionMode  string    `json:"retention_mode,omitempty"`
	LegalHold      bool      `json:"legal_hold"`
}

type ObjectSummary struct {
	Key            string    `json:"key"`
	Size           int64     `json:"size"`
	ETag           string    `json:"etag"`
	LastModified   time.Time `json:"last_modified"`
	RetentionUntil *int64    `json:"retention_until_unix_seconds,omitempty"`
	RetentionMode  string    `json:"retention_mode,omitempty"`
	LegalHold      bool      `json:"legal_hold"`
}

type ListObjectVersionsResponse struct {
	Items []ObjectVersion `json:"items"`
}

type ListBucketsResponse struct {
	Items []Bucket `json:"items"`
}

type CreateBucketRequest struct {
	Name          string  `json:"name" binding:"required"`
	Owner         string  `json:"owner,omitempty"`
	Versioning    bool    `json:"versioning,omitempty"`
	ObjectLocking bool    `json:"object_locking,omitempty"`
	MaxBytes      *uint64 `json:"max_bytes,omitempty"`
	MaxObjects    *uint64 `json:"max_objects,omitempty"`
}

type Object struct {
	Type         string    `json:"type,omitempty"`
	Key          string    `json:"key"`
	Size         int64     `json:"size"`
	ETag         string    `json:"etag"`
	LastModified time.Time `json:"last_modified"`
}

type ListObjectsResponse struct {
	Items             []Object    `json:"items"`
	CommonPrefixes    []string    `json:"common_prefixes,omitempty"`
	Directories       []Directory `json:"directories,omitempty"`
	IsTruncated       bool        `json:"is_truncated"`
	ContinuationToken string      `json:"continuation_token,omitempty"`
}

type Directory struct {
	Type         string    `json:"type"`
	Key          string    `json:"key"`
	LastModified time.Time `json:"last_modified"`
}

type DeleteDirectoryRequest struct {
	Key          string `json:"key" binding:"required"`
	AllVersions  bool   `json:"all_versions"`
	ForceCleanup bool   `json:"-"`
}

type CreateDirectoryRequest struct {
	Key string `json:"key" binding:"required"`
}

type PresignObjectRequest struct {
	AccessKey           string `json:"access_key,omitempty"`
	Bucket              string `json:"bucket" binding:"required"`
	Key                 string `json:"key" binding:"required"`
	Method              string `json:"method" binding:"required"`
	ExpiresSecond       int64  `json:"expires_seconds" binding:"required"`
	UploadID            string `json:"upload_id,omitempty"`
	PartNumber          int    `json:"part_number,omitempty" binding:"omitempty,min=1,max=10000"`
	VersionID           string `json:"version_id,omitempty"`
	CopySourceBucket    string `json:"copy_source_bucket,omitempty"`
	CopySourceKey       string `json:"copy_source_key,omitempty"`
	CopySourceVersionID string `json:"copy_source_version_id,omitempty"`
	Tagging             bool   `json:"tagging,omitempty"`
	Download            bool   `json:"download,omitempty"`
}

type PresignObjectResponse struct {
	URL             string            `json:"url"`
	ExpiresAt       time.Time         `json:"expires_at"`
	RequiredHeaders map[string]string `json:"required_headers"`
}

type MultipartUploadSummary struct {
	UploadID    string    `json:"upload_id"`
	Bucket      string    `json:"bucket"`
	Key         string    `json:"key"`
	InitiatedAt time.Time `json:"initiated_at"`
}

type MultipartPart struct {
	PartNumber   int       `json:"part_number"`
	Size         int64     `json:"size"`
	ETag         string    `json:"etag"`
	LastModified time.Time `json:"last_modified"`
}

type MultipartUpload struct {
	MultipartUploadSummary
	ContentType   string          `json:"content_type"`
	Parts         []MultipartPart `json:"parts"`
	UploadedBytes int64           `json:"uploaded_bytes"`
}

type ListMultipartUploadsResponse struct {
	Items              []MultipartUploadSummary `json:"items"`
	IsTruncated        bool                     `json:"is_truncated"`
	NextKeyMarker      string                   `json:"next_key_marker,omitempty"`
	NextUploadIDMarker string                   `json:"next_upload_id_marker,omitempty"`
}

type CreateMultipartUploadRequest struct {
	Bucket      string `json:"bucket" binding:"required"`
	Key         string `json:"key" binding:"required"`
	ContentType string `json:"content_type" binding:"required"`
}

type CompleteMultipartPartRequest struct {
	PartNumber int    `json:"part_number" binding:"required,min=1,max=10000"`
	ETag       string `json:"etag" binding:"required"`
}

type CompleteMultipartUploadRequest struct {
	Bucket string                         `json:"bucket" binding:"required"`
	Key    string                         `json:"key" binding:"required"`
	Parts  []CompleteMultipartPartRequest `json:"parts" binding:"required,min=1,max=10000,dive"`
}

type AccessKey struct {
	PolicyDocument string           `json:"policy_document"`
	Name           string           `json:"name"`
	Description    string           `json:"description"`
	InheritPolicy  bool             `json:"inherit_policy"`
	ID             string           `json:"id"`
	AccessKey      string           `json:"access_key"`
	SecretKey      string           `json:"secret_key,omitempty"`
	SessionToken   string           `json:"session_token,omitempty"`
	Kind           string           `json:"kind"`
	Owner          string           `json:"owner"`
	Enabled        bool             `json:"enabled"`
	Policy         CredentialPolicy `json:"policy"`
	CreatedAt      time.Time        `json:"created_at"`
	ExpiresAt      *time.Time       `json:"expires_at,omitempty"`
}

type CredentialPolicy struct {
	BucketRead                bool `json:"bucket_read"`
	BucketWrite               bool `json:"bucket_write"`
	ObjectRead                bool `json:"object_read"`
	ObjectWrite               bool `json:"object_write"`
	BypassGovernanceRetention bool `json:"bypass_governance_retention"`
}

type ListAccessKeysResponse struct {
	Items []AccessKey `json:"items"`
}

type CreateAccessKeyRequest struct {
	PolicyDocument string     `json:"policy_document,omitempty" binding:"max=262144"`
	AccessKey      string     `json:"access_key,omitempty" binding:"omitempty,min=16,max=128,alphanum"`
	SecretKey      string     `json:"secret_key,omitempty" binding:"omitempty,min=32,max=64"`
	Name           string     `json:"name" binding:"max=128"`
	Description    string     `json:"description" binding:"max=1024"`
	ExpiresAt      *time.Time `json:"expires_at,omitempty"`
	InheritPolicy  bool       `json:"inherit_policy"`

	Owner      string            `json:"owner,omitempty"`
	Policy     *CredentialPolicy `json:"policy,omitempty"`
	TTLSeconds *int64            `json:"ttl_seconds,omitempty" binding:"omitempty,min=60,max=43200"`
}

type CreateAccessKeyResponse struct {
	AccessKey
}

type UpdateAccessKeyRequest struct {
	Enabled        *bool      `json:"enabled,omitempty"`
	Name           *string    `json:"name,omitempty" binding:"omitempty,max=128"`
	Description    *string    `json:"description,omitempty" binding:"omitempty,max=1024"`
	InheritPolicy  *bool      `json:"inherit_policy,omitempty"`
	ExpiresAt      *time.Time `json:"expires_at,omitempty"`
	ClearExpiry    bool       `json:"clear_expiry,omitempty"`
	PolicyDocument *string    `json:"policy_document,omitempty" binding:"omitempty,max=262144"`
}

type StorageResponse struct {
	PhysicalUsed *int64 `json:"physical_used"`
	Measurement  string `json:"measurement"`
	Total        *int64 `json:"total"`
	Used         int64  `json:"used"`
	Available    *int64 `json:"available"`
}

type StorageScanReport struct {
	Partition               *int  `json:"partition"`
	Partitions              int   `json:"partitions"`
	ScannedGenerations      int   `json:"scanned_generations"`
	RetainedGenerations     int   `json:"retained_generations"`
	RemovedGenerations      int   `json:"removed_generations"`
	ScannedBytes            int64 `json:"scanned_bytes"`
	RetainedBytes           int64 `json:"retained_bytes"`
	RemovedBytes            int64 `json:"removed_bytes"`
	ExpiredMultipartUploads int   `json:"expired_multipart_uploads"`
}

type StorageScannerStatus struct {
	Running              bool               `json:"running"`
	LastCompletedAt      *int64             `json:"last_completed_at"`
	LastDurationMs       *int64             `json:"last_duration_ms"`
	LastAttemptSucceeded *bool              `json:"last_attempt_succeeded"`
	Partitions           int                `json:"partitions"`
	NextPartition        int                `json:"next_partition"`
	LastScan             *StorageScanReport `json:"last_scan"`
}

type ManagementHealthResponse struct {
	Status   string   `json:"status"`
	Recovery string   `json:"recovery"`
	Reason   string   `json:"reason"`
	Actions  []string `json:"actions"`
}

type ListenerSettings struct {
	APIAddress         string `json:"api_address"`
	AdminListenAddress string `json:"admin_listen_address"`
	UpstreamEndpoint   string `json:"upstream_endpoint"`
}
type SettingsResponse struct {
	PendingAPIAddress         string `json:"pending_api_address"`
	APIRestartRequired        bool   `json:"api_restart_required"`
	PendingAdminListenAddress string `json:"pending_admin_listen_address"`
	AdminRestartRequired      bool   `json:"admin_restart_required"`
	UpstreamEndpoint          string `json:"upstream_endpoint"`
	PendingUpstreamEndpoint   string `json:"pending_upstream_endpoint"`

	TrustedProxies               []string `json:"trusted_proxies"`
	AdminListenAddress           string   `json:"admin_listen_address"`
	APIAddress                   string   `json:"api_address"`
	S3PublicEndpoint             string   `json:"s3_public_endpoint"`
	S3VirtualHostedStyle         bool     `json:"s3_virtual_hosted_style"`
	S3Region                     string   `json:"s3_region"`
	RequestTimeSkewSeconds       int64    `json:"request_time_skew_seconds"`
	MultipartExpirySeconds       int64    `json:"multipart_expiry_seconds"`
	LifecycleScanIntervalSeconds int64    `json:"lifecycle_scan_interval_seconds"`
	StreamBufferSize             int64    `json:"stream_buffer_size"`
	MetricsEnabled               bool     `json:"metrics_enabled"`
	MetricsAddress               string   `json:"metrics_address"`
	AdminSessionTTLSeconds       int64    `json:"admin_session_ttl_seconds"`
	ReloadRequired               bool     `json:"reload_required"`
}

type ManagedPolicy struct {
	Name     string `json:"name"`
	Document string `json:"document"`
}
type PolicyList struct {
	Items []ManagedPolicy `json:"items"`
}

// Managed identities are persisted by ZigFS. Policy assignments are management metadata.
type UserWrite struct {
	Name        string    `json:"name" binding:"required"`
	Description string    `json:"description"`
	Enabled     bool      `json:"enabled"`
	Policies    []string  `json:"policies"`
	Password    *string   `json:"password,omitempty"`
	Groups      *[]string `json:"groups,omitempty"`
	TagsJSON    *string   `json:"tags_json,omitempty"`
}
type ManagedUser struct {
	Groups      []string `json:"groups"`
	UpdatedAt   int64    `json:"updated_at"`
	Name        string   `json:"name" binding:"required"`
	Description string   `json:"description"`
	Enabled     bool     `json:"enabled"`
	Policies    []string `json:"policies"`
	TagsJSON    string   `json:"tags_json,omitempty"`
}
type ManagedGroup struct {
	UpdatedAt   int64    `json:"updated_at"`
	Name        string   `json:"name" binding:"required"`
	Description string   `json:"description"`
	Enabled     bool     `json:"enabled"`
	Policies    []string `json:"policies"`
	Members     []string `json:"members"`
	TagsJSON    string   `json:"tags_json,omitempty"`
}
type UserList struct {
	Items []ManagedUser `json:"items"`
}
type GroupList struct {
	Items []ManagedGroup `json:"items"`
}

type BucketPolicy struct {
	Document string `json:"document"`
}

type Organization struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Enabled bool     `json:"enabled"`
	Paths   []string `json:"paths,omitempty"`
	Members []string `json:"members,omitempty"`
}
type Role struct {
	ID                  string   `json:"id"`
	Name                string   `json:"name"`
	OrganizationID      string   `json:"organization_id,omitempty"`
	Enabled             bool     `json:"enabled"`
	MaxSessionSeconds   uint64   `json:"max_session_seconds"`
	TrustPolicy         string   `json:"trust_policy"`
	Policies            []string `json:"policies,omitempty"`
	PermissionsBoundary string   `json:"permissions_boundary,omitempty"`
	TagsJSON            string   `json:"tags_json,omitempty"`
}
type OrganizationList struct {
	Items []Organization `json:"items"`
}
type RoleList struct {
	Items []Role `json:"items"`
}
type AssumeRoleRequest struct {
	RoleID                string `json:"role_id" binding:"required"`
	SessionName           string `json:"session_name" binding:"required"`
	DurationSeconds       uint64 `json:"duration_seconds,omitempty"`
	ExternalID            string `json:"external_id,omitempty"`
	SourceIdentity        string `json:"source_identity,omitempty"`
	SessionTagsJSON       string `json:"session_tags_json,omitempty"`
	TransitiveTagKeysJSON string `json:"transitive_tag_keys_json,omitempty"`
	SessionPolicy         string `json:"session_policy,omitempty"`
}
type AssumeRoleResponse struct {
	AccessKey    string `json:"access_key"`
	SecretKey    string `json:"secret_key"`
	SessionToken string `json:"session_token"`
	RoleID       string `json:"role_id"`
	SessionName  string `json:"session_name"`
	ExpiresAt    int64  `json:"expires_at"`
}
type RoleSession struct {
	AccessKey   string `json:"access_key"`
	RoleID      string `json:"role_id"`
	SessionName string `json:"session_name"`
	SubjectID   string `json:"subject_id"`
	ExpiresAt   int64  `json:"expires_at"`
	Revoked     bool   `json:"revoked"`
}
type RoleSessionList struct {
	Items []RoleSession `json:"items"`
}

type KMSConfig struct {
	Backend               string `json:"backend"`
	DefaultKey            string `json:"defaultKey"`
	StaticSecretKey       string `json:"staticSecretKey"`
	LocalKeyDirectory     string `json:"localKeyDirectory"`
	FilePermissions       string `json:"filePermissions"`
	LocalCacheEnabled     bool   `json:"localCacheEnabled"`
	Address               string `json:"address"`
	Token                 string `json:"token"`
	Namespace             string `json:"namespace"`
	MountPath             string `json:"mountPath"`
	KvMount               string `json:"kvMount"`
	KeyPathPrefix         string `json:"keyPathPrefix"`
	SkipTlsVerification   bool   `json:"skipTlsVerification"`
	CaCertificatePath     string `json:"caCertificatePath"`
	ClientCertificatePath string `json:"clientCertificatePath"`
	ClientKeyPath         string `json:"clientKeyPath"`
	TimeoutSeconds        string `json:"timeoutSeconds"`
	RetryCount            string `json:"retryCount"`
	CacheEnabled          bool   `json:"cacheEnabled"`
	CacheTtlSeconds       string `json:"cacheTtlSeconds"`
	CacheCapacity         string `json:"cacheCapacity"`
}
type KMSStatus struct {
	State                     string    `json:"state"`
	ErrorMessage              string    `json:"errorMessage"`
	HealthChecked             bool      `json:"healthChecked"`
	Healthy                   bool      `json:"healthy"`
	Configured                bool      `json:"configured"`
	Config                    KMSConfig `json:"config"`
	TokenConfigured           bool      `json:"tokenConfigured"`
	StaticSecretKeyConfigured bool      `json:"staticSecretKeyConfigured"`
}
