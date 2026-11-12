package service

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"

	"zigfs-admin/server/internal/config"
	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
)

func listenerError(status int, code string) error {
	return &port.StatusError{StatusCode: status, Code: code, Message: code}
}
func (service *Management) addListenerStatus(response *contract.SettingsResponse) {
	response.PendingAdminListenAddress = service.AdminListenAddress
	if service.Endpoint != nil {
		response.UpstreamEndpoint = service.Endpoint()
	}
	response.PendingUpstreamEndpoint = response.UpstreamEndpoint
	if saved, err := config.ReadListenerState(service.ListenerFile); err == nil {
		response.PendingAdminListenAddress = saved.AdminListenAddress
		response.AdminRestartRequired = saved.AdminListenAddress != service.AdminListenAddress
		response.PendingUpstreamEndpoint = saved.Endpoints[len(saved.Endpoints)-1]
	}
}
func (service *Management) SaveListeners(ctx context.Context, input contract.ListenerSettings) error {
	service.listenerMu.Lock()
	defer service.listenerMu.Unlock()
	// GET settings itself requires admin:* in ZigFS; no local write before this guard.
	_, err := service.zig.Settings(ctx)
	if err != nil {
		return err
	}
	if service.ListenerFile == "" || service.Endpoint == nil || service.SetEndpoints == nil {
		return listenerError(503, "ListenerSettingsUnavailable")
	}
	if config.ValidateListenAddress(input.APIAddress) != nil || config.ValidateListenAddress(input.AdminListenAddress) != nil {
		return listenerError(400, "InvalidListenAddress")
	}
	if config.ValidateEndpoint(input.UpstreamEndpoint) != nil {
		return listenerError(400, "InvalidUpstreamEndpoint")
	}
	if input.AdminListenAddress != service.AdminListenAddress {
		probe := input.AdminListenAddress
		host, targetPort, _ := net.SplitHostPort(probe)
		_, currentPort, _ := net.SplitHostPort(service.AdminListenAddress)
		if targetPort == currentPort {
			probe = net.JoinHostPort(host, "0")
		}
		listener, err := net.Listen("tcp", probe)
		if err != nil {
			return listenerError(409, "AdminListenAddressUnavailable")
		}
		listener.Close()
	}
	previous, err := config.ReadListenerState(service.ListenerFile)
	if errors.Is(err, os.ErrNotExist) {
		previous = config.ListenerState{AdminListenAddress: service.AdminListenAddress, Endpoints: []string{service.Endpoint()}}
	} else if err != nil {
		return listenerError(503, "ListenerSettingsUnavailable")
	}
	// Persist connectivity candidates before changing ZigFS, so an immediate
	// ZigFS restart cannot strand a subsequently restarted BFF.
	stage := config.ListenerState{AdminListenAddress: previous.AdminListenAddress, Endpoints: []string{service.Endpoint()}}
	if input.UpstreamEndpoint != stage.Endpoints[0] {
		stage.Endpoints = append(stage.Endpoints, input.UpstreamEndpoint)
	}
	if err = config.SaveListenerState(service.ListenerFile, stage); err != nil {
		return listenerError(503, "ListenerSettingsUnavailable")
	}
	service.SetEndpoints(stage.Endpoints)
	if err = service.zig.SaveListenerSettings(ctx, input.APIAddress); err != nil {
		// A definitive validation/authorization rejection leaves ZigFS unchanged.
		var rejection *port.StatusError
		if errors.As(err, &rejection) && rejection.StatusCode >= 400 && rejection.StatusCode < 500 {
			if restore := config.SaveListenerState(service.ListenerFile, previous); restore != nil {
				return listenerError(503, "ListenerSettingsPartiallySaved")
			}
			service.SetEndpoints(previous.Endpoints)
		}
		return err
	}
	stage.AdminListenAddress = input.AdminListenAddress
	if err = config.SaveListenerState(service.ListenerFile, stage); err != nil {
		return listenerError(http.StatusServiceUnavailable, "ListenerSettingsPartiallySaved")
	}
	return nil
}
