package push

import (
	"context"

	"github.com/w4jnl/doma/internal/service"
)

// ServiceRegistry is the Registry over the service.
type ServiceRegistry struct {
	Svc *service.Service
}

func (r ServiceRegistry) PushTargets(ctx context.Context, householdID string, notBefore int64) ([]Target, error) {
	rows, err := r.Svc.PushTargets(ctx, householdID, notBefore)
	if err != nil {
		return nil, err
	}
	out := make([]Target, 0, len(rows))
	for _, t := range rows {
		out = append(out, Target{CredentialID: t.CredentialID, Token: t.Token})
	}
	return out, nil
}

func (r ServiceRegistry) RecordPush(ctx context.Context, householdID, credentialID string, seq int64) error {
	return r.Svc.RecordPush(ctx, householdID, credentialID, seq)
}

func (r ServiceRegistry) ClearPushToken(ctx context.Context, credentialID string) error {
	return r.Svc.ClearPushToken(ctx, credentialID)
}

var _ Registry = ServiceRegistry{}
