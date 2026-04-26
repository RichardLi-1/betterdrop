package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/gorilla/websocket"
)

type handlers struct {
	sessions *sessionStore
}

func newHandlers(sessions *sessionStore) *handlers {
	return &handlers{sessions: sessions}
}

var upgrader = websocket.Upgrader{
	HandshakeTimeout: 10 * time.Second,
	CheckOrigin:      func(r *http.Request) bool { return true }, // auth is E2E via ECDH
}

// MARK: - Health

func (h *handlers) health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// MARK: - WebSocket signaling
//
// Both sender and recipient hit /connect.
// The sender includes ?senderID=&recipientID=&transferID= and creates a session.
// The recipient includes ?recipientID= only and waits for a session to be created for them.
//
// Message format (JSON):
//   { "type": "hello", "publicKey": "<base64>" }   — ECDH public key exchange
//   { "type": "session", "id": "<sessionID>" }      — relay tells sender the session ID

func (h *handlers) connect(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	senderID := q.Get("senderID")
	recipientID := q.Get("recipientID")
	transferID := q.Get("transferID")

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade: %v", err)
		return
	}
	defer conn.Close()
	conn.SetReadLimit(4 * 1024) // signaling messages are tiny

	if senderID != "" && recipientID != "" {
		h.handleSenderSignaling(conn, senderID, recipientID, transferID)
	} else if recipientID != "" {
		h.handleRecipientSignaling(conn, recipientID)
	} else {
		conn.WriteJSON(map[string]string{"type": "error", "message": "missing senderID or recipientID"})
	}
}

// Sender flow: create session → exchange public keys with recipient → send session ID.
func (h *handlers) handleSenderSignaling(
	conn *websocket.Conn,
	senderID, recipientID, transferID string,
) {
	// 1. Read sender's ECDH hello
	var senderHello map[string]string
	if err := conn.ReadJSON(&senderHello); err != nil || senderHello["type"] != "hello" {
		conn.WriteJSON(map[string]string{"type": "error", "message": "expected hello"})
		return
	}

	// 2. Create session and store sender's public key
	sess := h.sessions.create(senderID, recipientID, transferID)
	sess.mu.Lock()
	sess.senderPublicKey = senderHello["publicKey"]
	sess.mu.Unlock()

	// 3. Wait for recipient hello to arrive via the session
	recipientKey, ok := waitForRecipientKey(sess, 5*time.Minute)
	if !ok {
		conn.WriteJSON(map[string]string{"type": "error", "message": "recipient did not connect in time"})
		return
	}

	// 4. Forward recipient's public key to sender
	conn.WriteJSON(map[string]string{
		"type":      "hello",
		"publicKey": recipientKey,
	})

	// 5. Tell sender the session ID so it can start uploading chunks
	conn.WriteJSON(map[string]string{
		"type": "session",
		"id":   sess.id,
	})
}

// Recipient flow: wait for a session created for them → exchange public keys.
func (h *handlers) handleRecipientSignaling(conn *websocket.Conn, recipientID string) {
	// 1. Read recipient's ECDH hello
	var recipientHello map[string]string
	if err := conn.ReadJSON(&recipientHello); err != nil || recipientHello["type"] != "hello" {
		conn.WriteJSON(map[string]string{"type": "error", "message": "expected hello"})
		return
	}

	// 2. Wait for a session destined for this recipient (up to 5 minutes)
	sess, ok := h.sessions.waitForSession(recipientID, 5*time.Minute)
	if !ok {
		conn.WriteJSON(map[string]string{"type": "error", "message": "no sender connected"})
		return
	}

	// 3. Store recipient's key in session so sender can retrieve it
	sess.mu.Lock()
	sess.recipientPublicKey = recipientHello["publicKey"]
	for _, ch := range sess.recipientKeyWaiters {
		select {
		case ch <- recipientHello["publicKey"]:
		default:
		}
	}
	sess.mu.Unlock()

	// 4. Forward sender's public key to recipient
	sess.mu.Lock()
	senderKey := sess.senderPublicKey
	sess.mu.Unlock()

	conn.WriteJSON(map[string]string{
		"type":      "hello",
		"publicKey": senderKey,
	})

	// 5. Tell recipient their session ID and transfer ID
	conn.WriteJSON(map[string]string{
		"type":       "session",
		"id":         sess.id,
		"transferID": sess.transferID,
	})
}

func waitForRecipientKey(sess *session, timeout time.Duration) (string, bool) {
	ch := make(chan string, 1)
	sess.mu.Lock()
	if sess.recipientPublicKey != "" {
		key := sess.recipientPublicKey
		sess.mu.Unlock()
		return key, true
	}
	sess.recipientKeyWaiters = append(sess.recipientKeyWaiters, ch)
	sess.mu.Unlock()

	select {
	case key := <-ch:
		return key, true
	case <-time.After(timeout):
		return "", false
	}
}

// MARK: - Chunk upload (sender → relay)

func (h *handlers) uploadChunk(w http.ResponseWriter, r *http.Request) {
	sessID := r.PathValue("id")
	sess, ok := h.sessions.get(sessID)
	if !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	indexStr := r.Header.Get("X-Chunk-Index")
	index, err := strconv.Atoi(indexStr)
	if err != nil {
		http.Error(w, "invalid X-Chunk-Index", http.StatusBadRequest)
		return
	}

	const maxChunk = 600 * 1024 // 600 KB max (512 KB data + overhead for encryption)
	data, err := io.ReadAll(io.LimitReader(r.Body, maxChunk))
	if err != nil {
		http.Error(w, "read error", http.StatusInternalServerError)
		return
	}

	sess.addChunk(index, data)
	w.WriteHeader(http.StatusOK)
}

// MARK: - Chunk download (relay → recipient)
//
// The recipient polls GET /sessions/:id/chunks?index=N
// We long-poll for up to 30 seconds before returning 204 (try again).

func (h *handlers) downloadChunk(w http.ResponseWriter, r *http.Request) {
	sessID := r.PathValue("id")
	sess, ok := h.sessions.get(sessID)
	if !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	indexStr := r.URL.Query().Get("index")
	index, err := strconv.Atoi(indexStr)
	if err != nil {
		http.Error(w, "invalid index", http.StatusBadRequest)
		return
	}

	deadline := time.Now().Add(30 * time.Second)
	data, found := sess.waitForChunk(index, deadline)
	if !found {
		if sess.done {
			w.WriteHeader(http.StatusGone) // 410 = transfer complete, no more chunks
		} else {
			w.WriteHeader(http.StatusNoContent) // 204 = not yet, try again
		}
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Chunk-Index", strconv.Itoa(index))
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

// MARK: - Mark done

func (h *handlers) markDone(w http.ResponseWriter, r *http.Request) {
	sessID := r.PathValue("id")
	sess, ok := h.sessions.get(sessID)
	if !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}
	sess.markDone()
	w.WriteHeader(http.StatusOK)
}
