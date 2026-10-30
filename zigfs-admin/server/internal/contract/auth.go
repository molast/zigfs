package contract

type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

type LoginResponse struct {
	SubjectID string `json:"subject_id"`
	IsRoot    bool   `json:"is_root"`
	Token     string `json:"token"`
	TokenType string `json:"token_type"`
	Username  string `json:"username"`
	ExpiresAt int64  `json:"expires_at"`
}

type SessionResponse struct {
	SubjectID     string `json:"subject_id"`
	IsRoot        bool   `json:"is_root"`
	Authenticated bool   `json:"authenticated"`
	Username      string `json:"username"`
	ExpiresAt     int64  `json:"expires_at"`
}
