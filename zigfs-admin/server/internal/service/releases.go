package service

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type ReleaseCheck struct {
	CurrentVersion  string `json:"current_version"`
	LatestVersion   string `json:"latest_version"`
	UpdateAvailable bool   `json:"update_available"`
	ReleaseURL      string `json:"release_url"`
	CheckedAt       int64  `json:"checked_at"`
}

var versionPattern = regexp.MustCompile(`^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$`)

func parseReleaseVersion(value string) ([3]uint64, bool, error) {
	var parts [3]uint64
	match := versionPattern.FindStringSubmatch(value)
	if match == nil {
		return parts, false, fmt.Errorf("invalid release version")
	}
	for i := range parts {
		n, err := strconv.ParseUint(match[i+1], 10, 64)
		if err != nil {
			return parts, false, err
		}
		parts[i] = n
	}
	return parts, match[4] != "", nil
}

// CheckRelease checks published stable releases; failures never mean up to date.
func CheckRelease(ctx context.Context, current string, client *http.Client, endpoint, token string) (ReleaseCheck, error) {
	result := ReleaseCheck{CurrentVersion: current}
	currentParts, currentPrerelease, err := parseReleaseVersion(current)
	if err != nil {
		return result, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if client == nil {
		client = &http.Client{CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return result, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "ZigFS-Admin")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(request)
	if err != nil {
		return result, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return result, fmt.Errorf("release query returned HTTP %d", response.StatusCode)
	}
	var release struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&release); err != nil {
		return result, err
	}
	latest, prerelease, err := parseReleaseVersion(release.Tag)
	if err != nil || prerelease || release.Draft || release.Prerelease {
		return result, fmt.Errorf("invalid stable release")
	}
	for i := range latest {
		if latest[i] != currentParts[i] {
			result.UpdateAvailable = latest[i] > currentParts[i]
			break
		}
		if i == 2 {
			result.UpdateAvailable = currentPrerelease
		}
	}
	result.LatestVersion = strings.TrimPrefix(release.Tag, "v")
	// Construct the link from the validated tag, never render an upstream-supplied URL.
	result.ReleaseURL = "https://github.com/molast/zigfs/releases/tag/" + release.Tag
	result.CheckedAt = time.Now().Unix()
	return result, nil
}
