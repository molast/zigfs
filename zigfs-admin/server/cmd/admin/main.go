package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"zigfs-admin/server/internal/config"
	"zigfs-admin/server/internal/handler"
	"zigfs-admin/server/internal/router"
	"zigfs-admin/server/internal/service"
	"zigfs-admin/server/internal/zigclient"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("load configuration", "error", err)
		os.Exit(1)
	}

	client := zigclient.New(cfg.ZigEndpoint, cfg.ZigAdminToken, cfg.UpstreamTimeout)
	systemService := service.NewSystem(client)
	managementService := service.NewManagement(client)
	systemHandler := handler.NewSystem(systemService)
	managementHandler := handler.NewManagement(managementService)

	server := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           router.New(systemHandler, managementHandler, cfg.WebAdminToken, cfg.WebRoot),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	serverErrors := make(chan error, 1)
	go func() {
		slog.Info("zigfs-admin listening", "address", cfg.ListenAddress)
		serverErrors <- server.ListenAndServe()
	}()

	signalContext, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	select {
	case <-signalContext.Done():
		slog.Info("shutting down zigfs-admin")
	case err = <-serverErrors:
		if !errors.Is(err, http.ErrServerClosed) {
			slog.Error("http server stopped", "error", err)
			os.Exit(1)
		}
		return
	}

	shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err = server.Shutdown(shutdownContext); err != nil {
		slog.Error("graceful shutdown", "error", err)
		os.Exit(1)
	}
}
