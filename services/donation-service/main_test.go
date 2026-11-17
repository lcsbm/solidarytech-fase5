package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestHostFromDSN(t *testing.T) {
	cases := []struct {
		name, dsn, want string
	}{
		{"url completa", "postgresql://u:p@db.internal.example.com:5432/ngo_db?sslmode=require", "db.internal.example.com"},
		{"ip sem porta", "postgres://u:p@10.0.3.12/donation_db", "10.0.3.12"},
		{"endpoint rds", "postgresql://solidary_admin:x@solidarytech-production-donation.abc123.us-east-1.rds.amazonaws.com:5432/donation_db", "solidarytech-production-donation.abc123.us-east-1.rds.amazonaws.com"},
		{"nao e url", "nao-e-uma-url", "unknown"},
		{"vazio", "", "unknown"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := hostFromDSN(c.dsn); got != c.want {
				t.Errorf("hostFromDSN(%q) = %q, quer %q", c.dsn, got, c.want)
			}
		})
	}
}

func TestQueueNameFromURL(t *testing.T) {
	cases := []struct {
		name, url, want string
	}{
		{"url sqs", "https://sqs.us-east-1.amazonaws.com/603727984890/solidarytech-production-donations", "solidarytech-production-donations"},
		{"barra final", "https://sqs.us-east-1.amazonaws.com/603727984890/fila/", "fila"},
		{"so o nome", "fila", "fila"},
		{"vazio", "", "unknown"},
		{"so barra", "/", "unknown"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := queueNameFromURL(c.url); got != c.want {
				t.Errorf("queueNameFromURL(%q) = %q, quer %q", c.url, got, c.want)
			}
		})
	}
}

func TestHealthHandler(t *testing.T) {
	app := &App{}
	rec := httptest.NewRecorder()

	app.HealthHandler(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quer %d", rec.Code, http.StatusOK)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, quer application/json", ct)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("corpo nao e JSON valido: %v", err)
	}
	if body["status"] != "ok" || body["service"] != "donation-service" {
		t.Errorf("corpo = %v, quer status=ok e service=donation-service", body)
	}
}

func TestDonationHandlerRejectsUnsupportedMethod(t *testing.T) {
	app := &App{}
	rec := httptest.NewRecorder()

	app.DonationHandler(rec, httptest.NewRequest(http.MethodDelete, "/donations", nil))

	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("status = %d, quer %d", rec.Code, http.StatusMethodNotAllowed)
	}
}

func TestDonationHandlerRejectsInvalidPayload(t *testing.T) {
	app := &App{}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/donations", nil)

	app.DonationHandler(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, quer %d", rec.Code, http.StatusBadRequest)
	}
}

// O SLI de taxa de erros depende do middleware rotular cada resposta com o
// status HTTP correto. Este teste protege exatamente essa ligacao.
func TestInstrumentRecordsStatusLabel(t *testing.T) {
	const svc, endpoint = "test-svc", "/ping"

	handler := instrument(svc, endpoint, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})

	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest(http.MethodGet, endpoint, nil))

	if rec.Code != http.StatusTeapot {
		t.Fatalf("status propagado = %d, quer %d", rec.Code, http.StatusTeapot)
	}

	got := testutil.ToFloat64(requestCount.WithLabelValues(svc, http.MethodGet, endpoint, "418"))
	if got != 1 {
		t.Errorf("http_requests_total{status=418} = %v, quer 1", got)
	}
}

// Sem WriteHeader explicito, o Go envia 200 — o recorder precisa refletir isso,
// senao requisicoes bem-sucedidas sumiriam do denominador do SLI.
func TestInstrumentDefaultsTo200(t *testing.T) {
	const svc, endpoint = "test-svc", "/implicit"

	handler := instrument(svc, endpoint, func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	})

	handler(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, endpoint, nil))

	got := testutil.ToFloat64(requestCount.WithLabelValues(svc, http.MethodGet, endpoint, "200"))
	if got != 1 {
		t.Errorf("http_requests_total{status=200} = %v, quer 1", got)
	}
}
