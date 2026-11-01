package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
)

// AdminExists reports whether the setup page has been completed.
func (s *Service) AdminExists(ctx context.Context) (bool, error) {
	_, err := s.db.Read().GetAdmin(ctx)
	if err == nil {
		return true, nil
	}
	if errors.Is(notFound(err), domain.ErrNotFound) {
		return false, nil
	}
	return false, err
}

// Setup creates the admin login. It works once.
func (s *Service) Setup(ctx context.Context, login, password string) error {
	login = strings.TrimSpace(login)
	if login == "" || len(login) > 64 {
		return domain.Invalid("login", "give a name of up to 64 characters")
	}
	if len(password) < 10 {
		return domain.Invalid("password", "use at least 10 characters")
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return err
	}
	exists, err := s.AdminExists(ctx)
	if err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("%w: setup is done", domain.ErrConflict)
	}
	return s.db.Write().InsertAdmin(ctx, dbInsertAdmin(login, hash, s.nowMs()))
}

// VerifyAdmin checks the login; the work is the same whether or not the
// login matches.
func (s *Service) VerifyAdmin(ctx context.Context, login, password string) error {
	a, err := s.db.Read().GetAdmin(ctx)
	hash := ""
	if err == nil && a.Login == strings.TrimSpace(login) {
		hash = a.PasswordHash
	}
	if !auth.VerifyPassword(hash, password) {
		return domain.ErrUnauthorized
	}
	return nil
}
