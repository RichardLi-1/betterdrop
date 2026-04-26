package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

// A session represents one transfer rendezvous between a sender and recipient.
// The relay knows nothing about the file content — it just holds encrypted blobs.

type chunk struct {
	index int
	data  []byte // already ChaCha20-Poly1305 encrypted by the sender
}

type session struct {
	id          string
	senderID    string
	recipientID string
	transferID  string
	createdAt   time.Time

	mu                  sync.Mutex
	chunks              []chunk        // in arrival order
	done                bool           // sender called /done
	waiters             []chan struct{} // goroutines blocked in downloadChunk
	senderPublicKey     string         // base64 Curve25519 key from sender hello
	recipientPublicKey  string         // base64 Curve25519 key from recipient hello
	recipientKeyWaiters []chan string   // sender goroutine waiting for recipient to connect
}

func (s *session) addChunk(index int, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chunks = append(s.chunks, chunk{index: index, data: data})
	// Wake any blocked downloaders
	for _, ch := range s.waiters {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
	s.waiters = s.waiters[:0]
}

// waitForChunk blocks until chunk at the given index is available, the session
// is done, or the deadline fires. Returns (data, ok).
func (s *session) waitForChunk(index int, deadline time.Time) ([]byte, bool) {
	for {
		s.mu.Lock()
		for _, c := range s.chunks {
			if c.index == index {
				s.mu.Unlock()
				return c.data, true
			}
		}
		if s.done {
			s.mu.Unlock()
			return nil, false
		}
		// Register a waiter channel
		wake := make(chan struct{}, 1)
		s.waiters = append(s.waiters, wake)
		s.mu.Unlock()

		timeout := time.Until(deadline)
		if timeout <= 0 {
			return nil, false
		}
		select {
		case <-wake:
		case <-time.After(timeout):
			return nil, false
		}
	}
}

func (s *session) markDone() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.done = true
	for _, ch := range s.waiters {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
	s.waiters = s.waiters[:0]
}

// sessionStore holds all active sessions, with periodic GC for expired ones.
type sessionStore struct {
	mu       sync.RWMutex
	sessions map[string]*session

	// Index: recipientID → sessions waiting for them to connect
	byRecipient map[string][]*session

	// WebSocket waiter: recipientID → channel that fires when they connect
	recipientArrival map[string]chan string // sends session ID
}

func newSessionStore() *sessionStore {
	s := &sessionStore{
		sessions:         make(map[string]*session),
		byRecipient:      make(map[string][]*session),
		recipientArrival: make(map[string]chan string),
	}
	go s.gc()
	return s
}

func (ss *sessionStore) create(senderID, recipientID, transferID string) *session {
	id := randomID()
	sess := &session{
		id:          id,
		senderID:    senderID,
		recipientID: recipientID,
		transferID:  transferID,
		createdAt:   time.Now(),
	}

	ss.mu.Lock()
	ss.sessions[id] = sess
	ss.byRecipient[recipientID] = append(ss.byRecipient[recipientID], sess)
	ss.mu.Unlock()

	// Notify any waiting recipient
	ss.mu.RLock()
	ch := ss.recipientArrival[recipientID]
	ss.mu.RUnlock()
	if ch != nil {
		select {
		case ch <- id:
		default:
		}
	}

	return sess
}

func (ss *sessionStore) get(id string) (*session, bool) {
	ss.mu.RLock()
	defer ss.mu.RUnlock()
	s, ok := ss.sessions[id]
	return s, ok
}

// waitForSession blocks until a new session arrives for recipientID (or timeout).
func (ss *sessionStore) waitForSession(recipientID string, timeout time.Duration) (*session, bool) {
	ss.mu.Lock()
	// Check if there's already a session waiting
	if list := ss.byRecipient[recipientID]; len(list) > 0 {
		s := list[0]
		ss.byRecipient[recipientID] = list[1:]
		ss.mu.Unlock()
		return s, true
	}
	// Register a waiter
	ch := make(chan string, 1)
	ss.recipientArrival[recipientID] = ch
	ss.mu.Unlock()

	defer func() {
		ss.mu.Lock()
		delete(ss.recipientArrival, recipientID)
		ss.mu.Unlock()
	}()

	select {
	case id := <-ch:
		s, ok := ss.get(id)
		return s, ok
	case <-time.After(timeout):
		return nil, false
	}
}

// gc deletes sessions older than 2 hours every 10 minutes.
func (ss *sessionStore) gc() {
	for range time.Tick(10 * time.Minute) {
		cutoff := time.Now().Add(-2 * time.Hour)
		ss.mu.Lock()
		for id, s := range ss.sessions {
			if s.createdAt.Before(cutoff) {
				delete(ss.sessions, id)
			}
		}
		ss.mu.Unlock()
	}
}

func randomID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
