package handler

import (
	"crypto/subtle"
	"encoding/json"
	"github.com/gin-gonic/gin"
	"io"
	"net/http"
	"strings"
	"time"
	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/middleware"
)

func (handler *Management) OIDCProviders(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	var body json.RawMessage
	if ctx.Request.Method == http.MethodPost || ctx.Request.Method == http.MethodPatch {
		var err error
		body, err = io.ReadAll(http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024))
		if err != nil || !json.Valid(body) {
			writeError(ctx, http.StatusBadRequest, "InvalidRequest", "invalid OIDC configuration")
			return
		}
	}
	response, err := handler.service.OIDCProviders(ctx.Request.Context(), ctx.Request.Method, oidcProviderID(ctx), body)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	if ctx.Request.Method == http.MethodDelete {
		ctx.Status(http.StatusNoContent)
		return
	}
	status := http.StatusOK
	if ctx.Request.Method == http.MethodPost && !strings.HasSuffix(ctx.FullPath(), "/validate") {
		status = http.StatusCreated
	}
	ctx.Data(status, "application/json", response)
}

const oidcStateCookie = "zigfs_oidc_state"

func (handler *Management) OIDCLoginProviders(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	result, err := handler.service.OIDCAuth(ctx.Request.Context(), "GET", "providers", nil)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Data(http.StatusOK, "application/json", result)
}

func (handler *Management) OIDCLoginStart(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	ctx.Header("Referrer-Policy", "no-referrer")
	body, _ := json.Marshal(map[string]string{"provider_id": ctx.Param("id")})
	data, err := handler.service.OIDCAuth(ctx.Request.Context(), "POST", "start", body)
	if err != nil {
		ctx.Redirect(http.StatusSeeOther, "/?oidc_error=start")
		return
	}
	var result struct {
		URL   string `json:"authorization_url"`
		State string `json:"state"`
	}
	if json.Unmarshal(data, &result) != nil || result.URL == "" || len(result.State) != 64 {
		ctx.Redirect(http.StatusSeeOther, "/?oidc_error=start")
		return
	}
	ctx.SetSameSite(http.SameSiteLaxMode)
	ctx.SetCookie(oidcStateCookie, result.State, 300, "/api/v1/auth/oidc", "", ctx.Request.TLS != nil, true)
	ctx.Redirect(http.StatusSeeOther, result.URL)
}

func (handler *Management) OIDCLoginCallback(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	ctx.Header("Referrer-Policy", "no-referrer")
	expected, err := ctx.Cookie(oidcStateCookie)
	ctx.SetSameSite(http.SameSiteLaxMode)
	ctx.SetCookie(oidcStateCookie, "", -1, "/api/v1/auth/oidc", "", ctx.Request.TLS != nil, true)
	state := ctx.Query("state")
	if err != nil || len(state) != 64 || subtle.ConstantTimeCompare([]byte(expected), []byte(state)) != 1 || ctx.Query("error") != "" || ctx.Query("code") == "" {
		ctx.Redirect(http.StatusSeeOther, "/?oidc_error=callback")
		return
	}
	body, _ := json.Marshal(map[string]string{"state": state, "code": ctx.Query("code")})
	data, err := handler.service.OIDCAuth(ctx.Request.Context(), "POST", "callback", body)
	if err != nil {
		ctx.Redirect(http.StatusSeeOther, "/?oidc_error=callback")
		return
	}
	var result contract.LoginResponse
	if json.Unmarshal(data, &result) != nil || result.IsRoot || result.Token == "" || result.ExpiresAt <= time.Now().Unix() {
		ctx.Redirect(http.StatusSeeOther, "/?oidc_error=callback")
		return
	}
	expiry := result.ExpiresAt
	if result.CookieExpiresAt > expiry {
		expiry = result.CookieExpiresAt
	}
	maxAge := int(time.Until(time.Unix(expiry, 0)).Seconds())
	if maxAge < 1 {
		ctx.Redirect(http.StatusSeeOther, "/?oidc_error=callback")
		return
	}
	ctx.SetSameSite(http.SameSiteStrictMode)
	ctx.SetCookie(middleware.AdminSessionCookie, result.Token, maxAge, "/api", "", ctx.Request.TLS != nil, true)
	ctx.Redirect(http.StatusSeeOther, "/")
}

func (handler *Management) OIDCWebIdentity(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	body, err := io.ReadAll(http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 1024*1024))
	if err != nil || !json.Valid(body) {
		writeError(ctx, http.StatusBadRequest, "InvalidRequest", "invalid web identity request")
		return
	}
	response, err := handler.service.OIDCAuth(ctx.Request.Context(), "POST", "web-identity", body)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Data(http.StatusCreated, "application/json", response)
}

func oidcProviderID(ctx *gin.Context) string {
	if strings.HasSuffix(ctx.FullPath(), "/validate") {
		return "@validate"
	}
	return ctx.Param("id")
}

// Cookie-bound endpoints never accept a browser-supplied token in the JSON body.
func (handler *Management) OIDCRefresh(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	token, err := ctx.Cookie(middleware.AdminSessionCookie)
	if err != nil || !strings.HasPrefix(token, "o1.") {
		writeError(ctx, 401, "Unauthorized", "OIDC session required")
		return
	}
	body, _ := json.Marshal(map[string]string{"token": token})
	data, err := handler.service.OIDCAuth(ctx.Request.Context(), "POST", "refresh", body)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	var result contract.LoginResponse
	if json.Unmarshal(data, &result) != nil || result.IsRoot || result.Token != token || result.ExpiresAt <= time.Now().Unix() {
		writeError(ctx, 502, "InvalidUpstreamResponse", "invalid renewal response")
		return
	}
	// The fixed hard expiry is established at login; refresh does not extend the cookie.
	ctx.JSON(200, contract.SessionResponse{Authenticated: true, SubjectID: result.SubjectID, Username: result.Username, DisplayName: result.DisplayName, Email: result.Email, Federated: true, Refreshable: result.Refreshable, ExpiresAt: result.ExpiresAt})
}
func (handler *Management) OIDCEndSession(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	token, err := ctx.Cookie(middleware.AdminSessionCookie)
	if err != nil {
		writeError(ctx, 401, "Unauthorized", "OIDC session required")
		return
	}
	body, _ := json.Marshal(map[string]string{"token": token})
	data, err := handler.service.OIDCAuth(ctx.Request.Context(), "POST", "end-session", body)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.SetSameSite(http.SameSiteStrictMode)
	ctx.SetCookie(middleware.AdminSessionCookie, "", -1, "/api", "", ctx.Request.TLS != nil, true)
	ctx.Data(200, "application/json", data)
}
func (handler *Management) OIDCBackchannelLogout(ctx *gin.Context) {
	ctx.Header("Cache-Control", "no-store")
	ctx.Request.Body = http.MaxBytesReader(ctx.Writer, ctx.Request.Body, 128*1024)
	if err := ctx.Request.ParseForm(); err != nil || len(ctx.Request.PostForm["logout_token"]) != 1 {
		writeError(ctx, 400, "InvalidLogoutToken", "logout_token required")
		return
	}
	body, _ := json.Marshal(map[string]string{"provider_id": ctx.Param("id"), "logout_token": ctx.Request.PostForm.Get("logout_token")})
	_, err := handler.service.OIDCAuth(ctx.Request.Context(), "POST", "backchannel-logout", body)
	if err != nil {
		writeStorageError(ctx, err)
		return
	}
	ctx.Status(200)
}
