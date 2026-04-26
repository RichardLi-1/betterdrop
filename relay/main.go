package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	sessions := newSessionStore()
	h := newHandlers(sessions)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.health)

	// WebSocket signaling — sender and recipient both connect here.
	// Query params: senderID, recipientID, transferID
	mux.HandleFunc("GET /connect", h.connect)

	// File chunk relay
	mux.HandleFunc("POST /sessions/{id}/chunks", h.uploadChunk)
	mux.HandleFunc("GET /sessions/{id}/chunks",  h.downloadChunk)
	mux.HandleFunc("POST /sessions/{id}/done",   h.markDone)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      withLogging(mux),
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 0, // streaming downloads need no write timeout
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("BetterDrop relay listening on :%s", port)
	if err := srv.ListenAndServeTLS("cert.pem", "key.pem"); err != nil {
		// Fall back to plain HTTP for local dev
		log.Printf("TLS unavailable (%v), falling back to HTTP", err)
		srv.Handler = withLogging(mux)
		if err2 := srv.ListenAndServe(); err2 != nil {
			log.Fatalf("relay: %v", err2)
		}
	}
}

func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}
