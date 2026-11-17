package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

type Donation struct {
	ID        int       `json:"id"`
	NgoID     int       `json:"ngo_id"`
	Amount    float64   `json:"amount"`
	DonorName string    `json:"donor_name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type App struct {
	DB          *sql.DB
	SqsSvc      *sqs.SQS
	SqsQueueURL string
	DBHost      string
	ServiceName string
}

func main() {
	_ = godotenv.Load()

	shutdownTracer := initTracer()
	defer shutdownTracer()

	serviceName := os.Getenv("OTEL_SERVICE_NAME")
	if serviceName == "" {
		serviceName = "donation-service"
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL é obrigatória")
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil || db.Ping() != nil {
		log.Fatalf("Erro ao conectar ao banco de dados: %v", err)
	}
	log.Println("Conectado ao PostgreSQL (donation-service).")

	var sqsSvc *sqs.SQS
	queueURL := os.Getenv("AWS_SQS_URL")
	region := os.Getenv("AWS_REGION")
	if queueURL != "" && region != "" {
		sess, _ := session.NewSession(&aws.Config{Region: aws.String(region)})
		sqsSvc = sqs.New(sess)
		log.Println("Integração com AWS SQS ativada.")
	}

	app := &App{
		DB:          db,
		SqsSvc:      sqsSvc,
		SqsQueueURL: queueURL,
		DBHost:      hostFromDSN(dbURL),
		ServiceName: serviceName,
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/health", instrument(serviceName, "/health", app.HealthHandler))
	mux.HandleFunc("/donations", instrument(serviceName, "/donations", app.DonationHandler))

	handler := otelhttp.NewHandler(mux, "donation-service")

	log.Printf("donation-service rodando na porta %s", port)
	log.Fatal(http.ListenAndServe(":"+port, handler))
}

// hostFromDSN extrai o host do DATABASE_URL para o atributo server.address,
// exigido pelo New Relic para sintetizar a entidade PostgreSQL no Service Map.
func hostFromDSN(dsn string) string {
	u, err := url.Parse(dsn)
	if err == nil && u.Host != "" {
		return u.Hostname()
	}
	return "unknown"
}

// queueNameFromURL extrai o nome da fila da URL completa do SQS.
// O New Relic usa messaging.destination.name (nome, não URL) para sintetizar a entidade.
func queueNameFromURL(queueURL string) string {
	parts := strings.Split(strings.TrimSuffix(queueURL, "/"), "/")
	if name := parts[len(parts)-1]; name != "" {
		return name
	}
	return "unknown"
}

func (a *App) HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ok","service":"donation-service"}`))
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodPost {
		var d Donation
		if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
			http.Error(w, `{"error":"Payload inválido"}`, http.StatusBadRequest)
			return
		}

		d.Status = "APPROVED" // Simulação de gateway de pagamento

		ctx, span := a.startDBSpan(r.Context(), "INSERT INTO donations")
		err := a.DB.QueryRowContext(ctx,
			"INSERT INTO donations (ngo_id, amount, donor_name, status) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
			d.NgoID, d.Amount, d.DonorName, d.Status,
		).Scan(&d.ID, &d.CreatedAt)
		span.End()

		if err != nil {
			log.Printf("Erro ao salvar doação: %v", err)
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}

		if a.SqsSvc != nil {
			go a.sendNotificationEvent(r.Context(), d)
		}

		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(d)
		return
	}

	if r.Method == http.MethodGet {
		ctx, span := a.startDBSpan(r.Context(), "SELECT FROM donations")
		rows, err := a.DB.QueryContext(ctx,
			"SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC")
		span.End()

		if err != nil {
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()

		donations := []Donation{}
		for rows.Next() {
			var d Donation
			rows.Scan(&d.ID, &d.NgoID, &d.Amount, &d.DonorName, &d.Status, &d.CreatedAt)
			donations = append(donations, d)
		}

		json.NewEncoder(w).Encode(donations)
		return
	}

	http.Error(w, `{"error":"Método não permitido"}`, http.StatusMethodNotAllowed)
}

func (a *App) startDBSpan(ctx context.Context, statement string) (context.Context, trace.Span) {
	return otel.Tracer(a.ServiceName).Start(ctx, statement,
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String("db.system", "postgresql"),
			attribute.String("db.statement", statement),
			attribute.String("server.address", a.DBHost),
		),
	)
}

func (a *App) sendNotificationEvent(ctx context.Context, d Donation) {
	_, span := otel.Tracer(a.ServiceName).Start(ctx, "sqs SendMessage",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.destination.name", queueNameFromURL(a.SqsQueueURL)),
			attribute.String("messaging.operation", "publish"),
		),
	)
	defer span.End()

	body, _ := json.Marshal(d)
	_, err := a.SqsSvc.SendMessage(&sqs.SendMessageInput{
		MessageBody: aws.String(string(body)),
		QueueUrl:    aws.String(a.SqsQueueURL),
	})
	if err != nil {
		span.RecordError(err)
		log.Printf("Falha ao despachar evento SQS: %v", err)
	}
}
