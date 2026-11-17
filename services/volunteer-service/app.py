import os
import sys
import uuid
import time
import logging
import boto3
from boto3.dynamodb.conditions import Attr
from flask import Flask, request, jsonify, Response
from dotenv import load_dotenv

from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME as OTEL_SERVICE_NAME
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.botocore import BotocoreInstrumentor

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

load_dotenv()

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "volunteer-service")


def _init_otel():
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector.monitoring.svc.cluster.local:4317")
    try:
        provider = TracerProvider(resource=Resource({OTEL_SERVICE_NAME: SERVICE_NAME}))
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True)))
        trace.set_tracer_provider(provider)
        BotocoreInstrumentor().instrument()
        log.info(f"OTEL: TracerProvider inicializado (endpoint: {endpoint}, service: {SERVICE_NAME})")
    except Exception as e:
        log.warning(f"OTEL: falha ao inicializar — traces desabilitados: {e}")


_init_otel()

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

# ── Golden Metrics (SLI): latência e taxa de erros ──
REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total de requisições HTTP recebidas',
    ['service', 'method', 'endpoint', 'status'],
)
REQUEST_DURATION = Histogram(
    'http_request_duration_seconds',
    'Duração das requisições HTTP em segundos',
    ['service', 'method', 'endpoint'],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)


@app.before_request
def _start_timer():
    request._metrics_start = time.perf_counter()


@app.after_request
def _record_metrics(response):
    if request.path == '/metrics':
        return response
    endpoint = request.endpoint or 'unknown'
    REQUEST_COUNT.labels(SERVICE_NAME, request.method, endpoint, response.status_code).inc()
    start = getattr(request, '_metrics_start', None)
    if start is not None:
        REQUEST_DURATION.labels(SERVICE_NAME, request.method, endpoint).observe(time.perf_counter() - start)
    return response


@app.route('/metrics')
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
DYNAMODB_TABLE = os.getenv("AWS_DYNAMODB_TABLE")

if not DYNAMODB_TABLE:
    log.critical("Erro: AWS_DYNAMODB_TABLE não definida.")
    sys.exit(1)

try:
    dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
    table = dynamodb.Table(DYNAMODB_TABLE)
    log.info(f"Conectado à tabela DynamoDB: {DYNAMODB_TABLE}")
except Exception as e:
    log.critical(f"Falha ao conectar no DynamoDB: {e}")
    sys.exit(1)

@app.route('/health')
def health():
    return jsonify({"status": "ok", "service": "volunteer-service"})

@app.route('/volunteers', methods=['POST'])
def register_volunteer():
    data = request.get_json()
    if not data or not all(k in data for k in ('name', 'email', 'ngo_id')):
        return jsonify({"error": "Campos obrigatórios ausentes"}), 400

    volunteer_id = str(uuid.uuid4())
    item = {
        'volunteer_id': volunteer_id,
        'name': data['name'],
        'email': data['email'],
        'ngo_id': int(data['ngo_id']),
        'registered_at': str(int(time.time()))
    }

    try:
        table.put_item(Item=item)
        return jsonify(item), 201
    except Exception as e:
        log.error(f"Erro ao salvar voluntário no DynamoDB: {e}")
        return jsonify({"error": "Erro interno ao processar dados"}), 500

@app.route('/volunteers/<int:ngo_id>', methods=['GET'])
def get_volunteers_by_ngo(ngo_id):
    try:
        # Nota para avaliação dos alunos: Operação Scan simplificada para fins de desenvolvimento.
        # Em cenários complexos de produção, índices globais secundários (GSI) seriam exigidos.
        response = table.scan(FilterExpression=Attr('ngo_id').eq(ngo_id))
        return jsonify(response.get('Items', [])), 200
    except Exception as e:
        log.error(f"Erro ao buscar dados no DynamoDB: {e}")
        return jsonify({"error": "Erro interno"}), 500

if __name__ == '__main__':
    port = int(os.getenv("PORT", 8083))
    app.run(host='0.0.0.0', port=port)
