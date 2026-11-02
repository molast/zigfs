package contract

type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

type LoginResponse struct {
	CookieExpiresAt int64  `json:"cookie_expires_at"`
	DisplayName     string `json:"display_name"`
	Email           string `json:"email"`
	Federated       bool   `json:"federated"`
	Refreshable     bool   `json:"refreshable"`
	SubjectID       string `json:"subject_id"`
	IsRoot          bool   `json:"is_root"`
	Token           string `json:"token"`
	TokenType       string `json:"token_type"`
	Username        string `json:"username"`
	ExpiresAt       int64  `json:"expires_at"`
}

type SessionResponse struct {
	DisplayName   string `json:"display_name"`
	Email         string `json:"email"`
	Federated     bool   `json:"federated"`
	Refreshable   bool   `json:"refreshable"`
	SubjectID     string `json:"subject_id"`
	IsRoot        bool   `json:"is_root"`
	Authenticated bool   `json:"authenticated"`
	Username      string `json:"username"`
	ExpiresAt     int64  `json:"expires_at"`
}
