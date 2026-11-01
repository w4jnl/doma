package domain

import (
	"errors"
	"fmt"
)

// Sentinel errors every layer agrees on. Handlers map them to status codes;
// services never return sql.ErrNoRows.
var (
	// ErrNotFound covers everything outside the caller's households too, so
	// households cannot be enumerated.
	ErrNotFound = errors.New("not found")
	// ErrForbidden is a role that may not do this inside its own household.
	ErrForbidden = errors.New("forbidden")
	// ErrUnauthorized is a bad signature, an expired token or no session.
	ErrUnauthorized = errors.New("unauthorized")
	// ErrConflict is an invite already used or a uniqueness clash.
	ErrConflict = errors.New("conflict")
	// ErrQuota is a photo over the household's quota.
	ErrQuota = errors.New("over quota")
)

// ErrValidation names the field that is wrong.
type ErrValidation struct {
	Field string
	Msg   string
}

func (e ErrValidation) Error() string {
	if e.Field == "" {
		return e.Msg
	}
	return fmt.Sprintf("%s: %s", e.Field, e.Msg)
}

// Invalid builds an ErrValidation.
func Invalid(field, format string, a ...any) error {
	return ErrValidation{Field: field, Msg: fmt.Sprintf(format, a...)}
}
