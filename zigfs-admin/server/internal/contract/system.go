package contract

type HealthResponse struct {
	Status string `json:"status"`
}

type SystemResponse struct {
	Version     string `json:"version"`
	Uptime      int64  `json:"uptime"`
	StorageUsed int64  `json:"storage_used"`
	Objects     int64  `json:"objects"`
	Buckets     int64  `json:"buckets"`
}

type ErrorResponse struct {
	Code      string         `json:"code"`
	Message   string         `json:"message"`
	RequestID string         `json:"request_id"`
	Details   map[string]any `json:"details"`
}
