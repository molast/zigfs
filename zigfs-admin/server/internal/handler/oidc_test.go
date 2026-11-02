package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"zigfs-admin/server/internal/middleware"
)

type oidcStub struct {
	ManagementService
	calls    int
	response json.RawMessage
	err      error
}

func (s *oidcStub) OIDCAuth(_ context.Context, _, _ string, _ json.RawMessage) (json.RawMessage, error) {
	s.calls++
	return s.response, s.err
}

func TestOIDCCallbackRejectsMissingOrMismatchedStateBeforeExchange(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, cookie := range []string{"", strings.Repeat("b", 64)} {
		stub := &oidcStub{}
		router := gin.New()
		router.GET("/callback", NewManagement(stub).OIDCLoginCallback)
		request := httptest.NewRequest("GET", "/callback?state="+strings.Repeat("a", 64)+"&code=secret", nil)
		if cookie != "" {
			request.AddCookie(&http.Cookie{Name: oidcStateCookie, Value: cookie})
		}
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, request)
		if stub.calls != 0 || recorder.Code != 303 || recorder.Header().Get("Location") != "/?oidc_error=callback" {
			t.Fatal("invalid state reached exchange")
		}
		if strings.Contains(recorder.Body.String(), "secret") {
			t.Fatal("authorization code leaked")
		}
	}
}
func TestOIDCCallbackCookieAndFailureIsolation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, kind := range []string{"valid", "root", "expired", "upstream"} {
		t.Run(kind, func(t *testing.T) {
			expiry := time.Now().Add(time.Hour).Unix()
			if kind == "expired" {
				expiry = 1
			}
			body, _ := json.Marshal(map[string]any{"token": "o1.session", "expires_at": expiry, "is_root": kind == "root"})
			stub := &oidcStub{response: body}
			if kind == "upstream" {
				stub.err = errors.New("private upstream details")
			}
			router := gin.New()
			router.GET("/callback", NewManagement(stub).OIDCLoginCallback)
			state := strings.Repeat("a", 64)
			request := httptest.NewRequest("GET", "https://console.example/callback?state="+state+"&code=secret", nil)
			request.AddCookie(&http.Cookie{Name: oidcStateCookie, Value: state})
			recorder := httptest.NewRecorder()
			router.ServeHTTP(recorder, request)
			var session *http.Cookie
			for _, cookie := range recorder.Result().Cookies() {
				if cookie.Name == middleware.AdminSessionCookie {
					session = cookie
				}
			}
			if kind == "valid" {
				if session == nil || !session.HttpOnly || !session.Secure || session.SameSite != http.SameSiteStrictMode || session.Path != "/api" || session.MaxAge <= 0 {
					t.Fatal("unsafe or missing session cookie")
				}
				if recorder.Header().Get("Location") != "/" {
					t.Fatal("invalid redirect")
				}
			} else if session != nil || recorder.Header().Get("Location") != "/?oidc_error=callback" {
				t.Fatal("invalid upstream response authenticated user")
			}
			if recorder.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("callback must not be cached")
			}
		})
	}
}
func TestOIDCStartStateCookie(t *testing.T) {
	gin.SetMode(gin.TestMode)
	body, _ := json.Marshal(map[string]string{"authorization_url": "https://id.example/authorize", "state": strings.Repeat("a", 64)})
	router := gin.New()
	router.GET("/:id/start", NewManagement(&oidcStub{response: body}).OIDCLoginStart)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest("GET", "https://console.example/mock/start", nil))
	cookies := recorder.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != oidcStateCookie || !cookies[0].HttpOnly || !cookies[0].Secure || cookies[0].SameSite != http.SameSiteLaxMode || cookies[0].MaxAge != 300 {
		t.Fatal("unsafe state cookie")
	}
	if recorder.Code != 303 || recorder.Header().Get("Location") != "https://id.example/authorize" {
		t.Fatal("missing authorization redirect")
	}
}

func TestOIDCRefreshDoesNotExposeTokenAndRejectsRoot(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, root := range []bool{false, true} {
		body, _ := json.Marshal(map[string]any{"token": "o1.session", "subject_id": "external", "display_name": "External User", "email": "user@example.test", "expires_at": time.Now().Add(time.Minute).Unix(), "is_root": root})
		stub := &oidcStub{response: body}
		router := gin.New()
		router.POST("/refresh", NewManagement(stub).OIDCRefresh)
		request := httptest.NewRequest("POST", "/refresh", nil)
		request.AddCookie(&http.Cookie{Name: middleware.AdminSessionCookie, Value: "o1.session"})
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, request)
		expected := 200
		if root {
			expected = 502
		}
		if recorder.Code != expected || strings.Contains(recorder.Body.String(), "o1.session") {
			t.Fatal("unsafe refresh response", recorder.Code)
		}
	}
}
func TestOIDCRefreshCannotUseBodyTokenWithoutCookie(t *testing.T) {
	gin.SetMode(gin.TestMode)
	stub := &oidcStub{}
	router := gin.New()
	router.POST("/refresh", NewManagement(stub).OIDCRefresh)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest("POST", "/refresh", strings.NewReader(`{"token":"o1.attacker"}`)))
	if recorder.Code != 401 || stub.calls != 0 {
		t.Fatal("accepted unbound token")
	}
}
func TestOIDCBackchannelRejectsDuplicateToken(t *testing.T) {
	gin.SetMode(gin.TestMode)
	stub := &oidcStub{}
	router := gin.New()
	router.POST("/:id/logout", NewManagement(stub).OIDCBackchannelLogout)
	request := httptest.NewRequest("POST", "/provider/logout", strings.NewReader("logout_token=one&logout_token=two"))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)
	if recorder.Code != 400 || stub.calls != 0 {
		t.Fatal("ambiguous logout accepted")
	}
}
