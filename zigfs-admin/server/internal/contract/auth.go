package contract

type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

type LoginResponse struct {
	Token     string `json:"token"`
	TokenType string `json:"token_type"`
	Username  string `json:"username"`
	ExpiresAt int64  `json:"expires_at"`
}

type SessionResponse struct {
	Authenticated bool   `json:"authenticated"`
	Username      string `json:"username"`
	ExpiresAt     int64  `json:"expires_at"`
}
