package main

import (
	"errors"
	"sync"
)

var (
	ErrNotFound            = errors.New("not found")
	ErrDuplicate           = errors.New("duplicate")
	ErrIdempotencyConflict = errors.New("idempotency key already used with different sale")
)

type store struct {
	mu sync.RWMutex

	tenants    map[string]*Tenant
	tills      map[string]*Till
	attendants map[string]*Attendant
	sales      map[string]*Sale

	salesByIdempotency map[string]string
}

func newStore() *store {
	return &store{
		tenants:            make(map[string]*Tenant),
		tills:              make(map[string]*Till),
		attendants:         make(map[string]*Attendant),
		sales:              make(map[string]*Sale),
		salesByIdempotency: make(map[string]string),
	}
}

func (s *store) createTenant(tenant *Tenant) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.tenants[tenant.ID]; exists {
		return ErrDuplicate
	}

	s.tenants[tenant.ID] = tenant
	return nil
}

func (s *store) getTenant(id string) (*Tenant, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	tenant, ok := s.tenants[id]
	return tenant, ok
}

func (s *store) createTill(till *Till) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.tills[till.ID]; exists {
		return ErrDuplicate
	}

	if _, exists := s.tenants[till.TenantID]; !exists {
		return ErrNotFound
	}

	s.tills[till.ID] = till
	return nil
}

func (s *store) getTill(id string) (*Till, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	till, ok := s.tills[id]
	return till, ok
}

func (s *store) createAttendant(attendant *Attendant) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.attendants[attendant.ID]; exists {
		return ErrDuplicate
	}

	if _, exists := s.tenants[attendant.TenantID]; !exists {
		return ErrNotFound
	}

	s.attendants[attendant.ID] = attendant
	return nil
}

func (s *store) getAttendant(id string) (*Attendant, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	attendant, ok := s.attendants[id]
	return attendant, ok
}

func (s *store) createSale(sale *Sale) (*Sale, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if existingSaleID, exists := s.salesByIdempotency[sale.IdempotencyKey]; exists {
		existingSale := s.sales[existingSaleID]

		if existingSale.AmountMinor != sale.AmountMinor ||
			existingSale.TenantID != sale.TenantID ||
			existingSale.TillID != sale.TillID {
			return nil, false, ErrIdempotencyConflict
		}

		return existingSale, true, nil
	}

	if _, exists := s.sales[sale.ID]; exists {
		return nil, false, ErrDuplicate
	}

	s.sales[sale.ID] = sale
	s.salesByIdempotency[sale.IdempotencyKey] = sale.ID

	return sale, false, nil
}

func (s *store) getSale(id string) (*Sale, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	sale, ok := s.sales[id]
	return sale, ok
}
