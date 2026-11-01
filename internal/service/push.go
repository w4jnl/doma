package service

import (
	"context"

	"github.com/w4jnl/doma/internal/db"
)

// PushTarget is a device to push to.
type PushTarget struct {
	CredentialID string
	Token        string
}

// PushTargets returns the household's devices with a token that were not
// pushed since notBefore.
func (s *Service) PushTargets(ctx context.Context, householdID string, notBefore int64) ([]PushTarget, error) {
	rows, err := s.db.Read().PushTargets(ctx, db.PushTargetsParams{HouseholdID: householdID, SentAt: notBefore})
	if err != nil {
		return nil, err
	}
	out := make([]PushTarget, 0, len(rows))
	for _, r := range rows {
		if r.ApnsToken != nil {
			out = append(out, PushTarget{CredentialID: r.CredentialID, Token: *r.ApnsToken})
		}
	}
	return out, nil
}

// RecordPush notes a push so the next one to the device waits 30 s.
func (s *Service) RecordPush(ctx context.Context, householdID, credentialID string, seq int64) error {
	return s.db.Write().RecordPush(ctx, db.RecordPushParams{HouseholdID: householdID, CredentialID: credentialID, SentAt: s.nowMs(), Seq: seq})
}

// ClearPushToken forgets a token Apple says is gone.
func (s *Service) ClearPushToken(ctx context.Context, credentialID string) error {
	return s.db.Write().ClearAPNSToken(ctx, credentialID)
}
