package contract

type HealthResponse struct {
	Status string `json:"status"`
}

type BuildInfo struct {
	BuiltAt         int64  `json:"built_at"`
	GitCommit       string `json:"git_commit"`
	ZigVersion      string `json:"zig_version"`
	OperatingSystem string `json:"operating_system"`
	Architecture    string `json:"architecture"`
	Mode            string `json:"mode"`
}
type ProcessMetrics struct {
	ResidentBytes    uint64  `json:"resident_bytes"`
	CPUSeconds       float64 `json:"cpu_seconds"`
	SampledAtSeconds float64 `json:"sampled_at_seconds"`
}
type SystemResponse struct {
	Build       *BuildInfo      `json:"build"`
	Process     *ProcessMetrics `json:"process"`
	Version     string          `json:"version"`
	Uptime      int64           `json:"uptime"`
	StorageUsed int64           `json:"storage_used"`
	Objects     int64           `json:"objects"`
	Buckets     int64           `json:"buckets"`
}

type ErrorResponse struct {
	Code      string         `json:"code"`
	Message   string         `json:"message"`
	RequestID string         `json:"request_id"`
	Details   map[string]any `json:"details"`
}
