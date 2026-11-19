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

	"github.com/molast/zigfs/pkg/gateway"
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

	client := zigclient.New(cfg.ZigEndpoint, cfg.UpstreamTimeout)
	client.SetEndpoints(cfg.EndpointCandidates)
	authService := service.NewAuth(client)
	systemService := service.NewSystem(client)
	managementService := service.NewManagement(client)
	managementService.AdminListenAddress = cfg.ListenAddress
	managementService.ListenerFile = cfg.ListenerFile
	managementService.SetEndpoints = client.SetEndpoints
	managementService.Endpoint = client.Endpoint
	authHandler := handler.NewAuth(authService)
	systemHandler := handler.NewSystem(systemService)
	managementHandler := handler.NewManagement(managementService)

	edge := gateway.New(cfg.GatewayDirectory, client.Endpoint)
	managementHandler.Gateway = edge
	managementHandler.GatewayAudit = client.ReportGatewayEvent
	routes := router.New(authHandler, systemHandler, managementHandler, cfg.WebRoot)
	edge.Start(routes)
	if status := edge.Status(); status.Error != "" {
		slog.Error("HTTPS gateway unavailable; HTTP recovery remains available", "error", status.Error)
	}
	maintenanceContext, stopMaintenance := context.WithCancel(context.Background())
	defer stopMaintenance()
	go edge.Maintain(maintenanceContext)
	go edge.RunLocalDNS(maintenanceContext)

	server := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           routes,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      cfg.UpstreamTimeout + 30*time.Second,
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
	stopMaintenance()
	edge.Shutdown(shutdownContext)
	if err = server.Shutdown(shutdownContext); err != nil {
		slog.Error("graceful shutdown", "error", err)
		os.Exit(1)
	}
}
