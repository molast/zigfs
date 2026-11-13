package contract

type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

type STSLoginRequest struct {
	Username     string `json:"username" binding:"required"`
	SecretKey    string `json:"secret_key" binding:"required"`
	SessionToken string `json:"session_token" binding:"required"`
}

type LoginResponse struct {
	CookieExpiresAt int64        `json:"cookie_expires_at"`
	DisplayName     string       `json:"display_name"`
	Email           string       `json:"email"`
	Federated       bool         `json:"federated"`
	Refreshable     bool         `json:"refreshable"`
	SubjectID       string       `json:"subject_id"`
	IsRoot          bool         `json:"is_root"`
	Token           string       `json:"token"`
	TokenType       string       `json:"token_type"`
	Username        string       `json:"username"`
	ExpiresAt       int64        `json:"expires_at"`
	Capabilities    Capabilities `json:"capabilities"`
}

type Capabilities struct {
	S3Console   bool `json:"s3_console"`
	KMSList     bool `json:"kms_list"`
	KMSDescribe bool `json:"kms_describe"`
	ServerInfo  bool `json:"server_info"`
	ConsoleLog  bool `json:"console_log"`
	Admin       bool `json:"admin"`
	KMS         bool `json:"kms"`
	S3          bool `json:"s3"`
	STS         bool `json:"sts"`
}

type DisplayPreferences struct {
	Timezone   string `json:"timezone"`
	DateFormat string `json:"date_format"`
}

type SessionResponse struct {
	Policies           []string            `json:"policies"`
	AuthSource         string              `json:"auth_source"`
	RootAccessKey      *string             `json:"root_access_key"`
	SessionAccessKey   *string             `json:"session_access_key"`
	DisplayPreferences *DisplayPreferences `json:"display_preferences"`
	DisplayName        string              `json:"display_name"`
	Email              string              `json:"email"`
	Federated          bool                `json:"federated"`
	Refreshable        bool                `json:"refreshable"`
	SubjectID          string              `json:"subject_id"`
	IsRoot             bool                `json:"is_root"`
	Authenticated      bool                `json:"authenticated"`
	Username           string              `json:"username"`
	ExpiresAt          int64               `json:"expires_at"`
	Capabilities       Capabilities        `json:"capabilities"`
}
